# Alexa RubyEngine
# This Engine receives and responds to Amazon Echo's (Alexa) JSON requests.
require 'sinatra'
require 'json'
require 'bundler/setup'
require 'alexa_rubykit'
require 'uri'
require 'open-uri'
require 'openssl-extensions/all'
require 'httparty'
require 'staccato'

configure :production do
  tracker = Staccato.tracker('UA-76358136-1')
  tracker.pageview()
  tracker.event()
end

get '/' do
  erb :'index.html'
end

#enable :sessions
post '/' do
  content_type('application/json')
  if settings.production?
    @sig_url = request.env['HTTP_SIGNATURECERTCHAINURL']
    @uri = URI.parse(@sig_url)
    @host = @uri.host.downcase
    @filename = URI(@uri).path.split('/').last  
  end
  
  @body = request.body.read
  @request_json = JSON.parse(@body.to_s)
  
  def check_https 
    @sig_url =~ /\A#{URI::regexp(['https'])}\z/
    @sig_url != nil
  end
  
  def check_scheme
    @uri.scheme == 'https'
  end
  
  def check_host
    @host == 's3.amazonaws.com'
  end
  
  def check_path
    @uri.path.start_with?('/echo.api/')
  end
  
  def check_port
    @uri.port == 443
  end
  
  def check_within150
    @timestamp = Time.parse @request_json['request']['timestamp']
    @start = Time.now.getutc - 150
    @end = Time.now.getutc + 150 
    (@start.to_i..@end.to_i).include?(@timestamp.to_i)
  end
  
  #save the pem
  def save_pem
    File.open(@filename, "wb") do |saved_file|
      # the following "open" is provided by open-uri
      open(@sig_url, "rb") do |read_file|
        saved_file.write(read_file.read)
      end
    end
  end

  # check the pem
  def read_pem
    raw = File.read @filename # DER- or PEM-encoded
    @certificate = OpenSSL::X509::Certificate.new raw 
  end
  
  def check_cert_expire
    # The signing certificate has not expired (examine both the Not Before and Not After dates)
    @now = Time.now.getutc
    @c_start = @certificate.not_before
    @c_end = @certificate.not_after    
    (@c_start.to_i..@c_end.to_i).include?(@now.to_i)
  end
  
  def check_cert_san
    @san_array = @certificate.subject_alternative_names
    @san_array.include?("echo-api.amazon.com")
  end
  
  def verify_cert
    @sig_header = request.env["HTTP_SIGNATURE"]
    @digest = OpenSSL::Digest::SHA1.new
    @signature = Base64.decode64(@sig_header) 
    @certificate.public_key.verify(@digest, @signature, @body)
  end
  
  if settings.production?
    save_pem
    read_pem
    halt 403 unless check_https && check_scheme && check_host && check_path && check_port && check_within150 && check_cert_expire && check_cert_san && verify_cert
  end 
  
  alexa_request = AlexaRubykit.build_request(@request_json)
  # We can capture Session details inside of request.
  # See session object for more information.
  session = alexa_request.session

  # We need a response object to respond to the Alexa.
  response = AlexaRubykit::Response.new
  end_session = true
  # Response
  # If it's a launch request
  if (alexa_request.type == 'LAUNCH_REQUEST')
    # Process your Launch Request
    # Call your methods for your application here that process your Launch Request.
    response.add_speech('Welcome to Single Quote!  What stock symbol would you like a quote for?')
    response.add_hash_card( { :title => 'Single Quote', :subtitle => 'Diversify your bonds!' } )
    response.add_reprompt("I provide quote information for most widely traded companies by their symbol, like AMZN, or TSLA. Which quote would you like? ")
    end_session = false
  end

  if (alexa_request.type == 'INTENT_REQUEST')
    # Process your Intent Request
    if (alexa_request.name == 'GetQuote')
      @symbol_raw = alexa_request.slots['SymbolRequest']['value']
      @symbol = @symbol_raw.gsub(/[^A-Za-z]/, '').upcase
      if @symbol.nil?
        response.add_speech("I'm sorry, I didn't catch that stock symbol. Which quote would you like?")
        end_session = false
      else
        @output = Markit.new.find_quote(@symbol).output
        if @output["Error"]
          response.add_speech("I'm sorry, I couldn't find that listing.  I provide quote information for most widely traded companies by their symbol, like AMZN, or TSLA. Which quote would you like? ")
        end_session = false
        else
          @ltp = @output["StockQuote"]["LastPrice"]
          @change_float = @output["StockQuote"]["ChangePercent"].to_f
          @change = @change_float.round(2).to_s
          @name = @output["StockQuote"]["Name"]
          
          if @change_float > 0
            @change_sign = "up"
            @changestr = "#{@change_sign} #{@change}"
          elsif @change_float < 0
            @change_sign = "down"
            @changestr = "#{@change_sign} #{@change}"
          else
            @changestr = "unchanged"
          end
          
          response.add_speech("The last traded price of #{@name} is #{@ltp}, #{@changestr} percent")
          @card_string = "#{@ltp}, #{@change}%"
          response.add_hash_card( { :title => @symbol, :content => @card_string } )  
        end
      end
    elsif (alexa_request.name == 'AMAZON.HelpIntent')
      response.add_speech("I provide quote information for most widely traded companies by their symbol, like AMZN, or TSLA. Which quote would you like? ")
      response.add_hash_card( { :title => "Help", :content => "Stock symbols are expected to be spelled out.  Quotes are limited to equities.  Mutual funds and ETFS are not yet supported.  Buy low.  Sell high." } ) 
      end_session = false      
    elsif (alexa_request.name == 'AMAZON.StopIntent')
    end    
    
  end

  
  if (alexa_request.type =='SESSION_ENDED_REQUEST')
    # Wrap up whatever we need to do.
    # p "#{alexa_request.type}"
    # p "#{alexa_request.reason}"
    halt 200
  end
  
  

  # Return response
  response.build_response end_session
end

  class Markit
  
    # quote_url = "select * from yahoo.finance.quotes where symbol = '#{symbol}'"
    def find_quote symbol
      Quote.new HTTParty.get("http://dev.markitondemand.com/MODApis/Api/v2/Quote?symbol=#{symbol}")
    end
  end
  class Quote
    def initialize(response)
      @response = response
    end
 
    def output
      @response#["StockQuote"]["results"]["quote"]
    end
  end
  
