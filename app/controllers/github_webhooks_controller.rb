# app/controllers/github_webhooks_controller.rb
require 'json'
require 'git'
require 'uri'
require'net/http'
require 'pp'
# xml processing
require 'nokogiri'

class GithubWebhooksController < ActionController::Base
  include GithubWebhook::Processor

  # needed this to turn off CSRF for API access
  skip_forgery_protection


  # Handle push event
  def github_push(payload)

    # basic variables
    base_url = "https://172.19.101.227"
    auth_header = "Basic YmFybmVzcnk6MTIzRGVtbw=="  # barnesry:123Demo
    addressfile = '/home/barnesry/github/firewall-automation-demo/addresses.xml'
    # labuser = "barnesry"
    # labpass = "123Demo"
    # sd_ip = '172.19.101.227'
    # sdapi_url = "https://#{sd_ip}/api/juniper/sd/address-management/addresses"

    # setup our HTTPS session to Security Director
    url = URI(base_url)
    https = Net::HTTP.new(url.host, url.port);
    https.use_ssl = true
    https.verify_mode = OpenSSL::SSL::VERIFY_NONE if https.use_ssl?

    puts
    puts "GOT : #{payload["commits"].inspect}"
    puts

    # get url to refresh from webhook input
    repo_url = payload["repository"]["url"]
    git_dir = "/home/barnesry/github/firewall-automation-demo"
    
    # blindly perform a pull for the demo w/o any checks
    puts "Performing a GIT PULL for #{repo_url} to refresh..."
    g = Git.open(git_dir)
    g.pull
    
    # display the diff to the console
    puts "-"*30
    puts "GIT DIFF"
    puts "-"*30
    puts "#{g.diff("HEAD^", "HEAD").patch}"
    puts
    puts


    # open our refreshed source file
    contents = File.read(addressfile)
    puts "-"*30
    puts "File Contents"
    puts "-"*30
    puts contents
    
    xmldata = Nokogiri::XML(contents)

    # since my input is XML, parse then...
    # for each address element look up in SD API
    # and perform an update (if exists) or add (if not exists)
    # ** super inefficient but good enough for demo only **
    xmldata.xpath('//address').each do |address|
   
      new_address = address.at_xpath('ip-address').content
      new_description = address.at_xpath('description').content
      search_name = address.at_xpath('name').content
      puts "Checking SD API for #{search_name}"

      # in case I need to convert from XML to JSON
      # JSON.generate(Hash.from_xml(xmlroot.to_s))

      #Now we need to make the API call to SD
      
      # payload = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      # <addresses>
      #   <address>
      #       <name>GOOGLEDNS3</name>
      #       <address-type>IPADDRESS</address-type>
      #       <ip-address>8.8.8.8</ip-address>
      #       <description>SD API Update</description>
      #       <definition-type>CUSTOM</definition-type>
      #   </address>
      # </addresses>'''
      
      # check if address entry exists already in the SD Addresses
      # using filter eq name
      check_results = address_exist?(https, base_url, search_name)
      if check_results

          # if true, then an entry already exists and we need to update it 
          # Construct update URL for POST from uri provided in the GET
          update_url = base_url + check_results["uri"]
          url = URI(update_url)

          # method not working yet
          # response = update_address_object(update_url, address, https=https)

          request = Net::HTTP::Put.new(url)
          request["Authorization"] = auth_header
          request["Content-Type"] = "application/json"
          request["Accept"] = "application/json"
          
          # we need to add an extra 'address' key to our JSON results 
          # returned from the query before submitting for update
          update_address = {}
          update_address["address"] = check_results

          # update our new IP and description
          old_ip_address = update_address["address"]["ip_address"]
          old_description = update_address["address"]["description"]
          update_address["address"]["ip_address"] = new_address
          update_address["address"]["description"] = new_description
          pp(update_address)
          
          # generate our JSON request body
          new_body = JSON.generate(update_address)

          # update 'PUT' the new updated address
          request.body = new_body

          puts "SUBMITTING..."
          response = https.request(request)
          
          if response.code == "200"
              puts "UPDATE SUCCESSFUL! Reponse Code : #{response.code}"
          else
              puts "Something went wrong with our update"
              # need to perform proper error handling here
          end

      else
          # else we should create it via POST method
          
          # test data structure
          # body = {"address"=>
          # {"addr_name"=>"GOOGLEDNS2",
          #  "name"=>"GOOGLEDNS2",
          #  "address_type"=>"IPADDRESS",
          #  "ip_address"=>"8.8.8.10",
          #  "description"=>"SD API Update",
          #  "definition_type"=>"CUSTOM",
          # }}

          # Rails shortcut to convert from XML to JSON
          body = JSON.generate(Hash.from_xml(address.to_s))
          
          create_address_object(https, base_url, body)

      end
    end
  end

  # Handle create event
  def github_ping(payload)
    
    head :ok, content_type: "text/html"
  end

  private

  def webhook_secret(payload)
    ENV['GITHUB_WEBHOOK_SECRET']
  end

  #########################
  # Security Director API #
  #########################
  def address_exist?(https, base_url, name)
    ''' checks for the existence of an address-book entry matching provided name using an eq filter by name '''

    # build our GET URL
    get_uri = "/api/juniper/sd/address-management/v5/address?filter=(name eq '#{name}')"
    get_url = base_url + get_uri
    url = URI(get_url)

    # build our GET request
    request = Net::HTTP::Get.new(url)
    request["Authorization"] = "Basic YmFybmVzcnk6MTIzRGVtbw=="
    request["Accept"] = "application/json"

    puts "Searching for #{name} at #{url.to_s}"

    response = https.request(request)
    #puts response.read_body
    body = JSON.parse(response.read_body)
    
    # puts "RESULT MATCHES : #{body["addresses"]["total"]}"

    if body["addresses"]["total"] == 1
        return body["addresses"]["address"][0]
    else 
        return false
    end
  end

  def create_address_object(https, base_url, body)
    ''' Inputs : 
            json : as body for the address to update
            url  :  as a string
    '''
    
    # build our POST url
    create_uri = "/api/juniper/sd/address-management/v5/address"
    create_url =  base_url + create_uri
    url = URI(create_url)
        
    request = Net::HTTP::Post.new(url)
    request["Authorization"] = "Basic YmFybmVzcnk6MTIzRGVtbw=="
    request["Content-Type"] = "application/json"
    request["Access-Type"] = "application/json"

    request.body = JSON.generate(body)
    
    puts "Creating new entry for #{body} at #{url.to_s}"

    response = https.request(request)
    puts response.read_body

  end
end