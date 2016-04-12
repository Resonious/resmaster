require 'net/http'
require 'json'
require 'websocket-eventmachine-client'
require 'os'
# require 'active_support'
# require 'active_support/core_ext'
require 'recursive_open_struct'
require 'base64'

DISCORD_API = 'https://discordapp.com/api'
RESMASTER_TOKEN = "MTY4ODY2MDQ5NjI0NzY4NTEy.Ce6SZw.K9oArZ6pIbD7_6b4_aYW1500kzA"
VERSION = "0.0.1"

module Api
  def connect(uri, token)
    @token = token
    @endpoint = URI(uri)

    http = Net::HTTP.new(@endpoint.host, @endpoint.port)
    if http.use_ssl = @endpoint.scheme == 'https'
      if OS.windows?
        http.ca_file = File.join((File.dirname File.expand_path __FILE__), 'win-cacert.pem')
      end
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.verify_depth = 5
    end
    @http = http.start
  end

  def gzip(str)
    io = StringIO.new
    gz = Zlib::GzipWriter.new(io)
    gz.write str
    gz.close
    io.string
  end

  def gunzip(str)
    io = StringIO.new(str)
    gz = Zlib::GzipReader.new(io)
    unz = gz.read
    gz.close
    unz
  end

  def get(path)
    full_path = net_path(path)

    response = @http.get(full_path, headers)
    yield response if block_given?
    return_valid_body('GET', path, response)
  end

  def patch(path, data)
    full_path = net_path(path)

    response = @http.patch(full_path, process_data(data), headers)
    yield response if block_given?
    return_valid_body('PATCH', path, response)
  end

  def post(path, data)
    full_path = net_path(path)

    response = @http.post(full_path, process_data(data), headers)
    yield response if block_given?
    return_valid_body('POST', path, response)
  end

  def avatar_file(filename)
    file_bytes = IO.binread(filename)
    "data:image/jpeg;base64,#{Base64.strict_encode64(file_bytes)}"
  end

  def gateway_url
    @gateway_url ||= get('/gateway').url
  end

  protected

  def process_data(data)
    # gzip data.to_json
    data.to_json
  end

  def return_valid_body(method, path, response)
    if response.code.to_i == 200
      if response.header['content-encoding'] && response.header['content-encoding'] =~ /gzip/
        body = gunzip response.body
      else
        body = response.body
      end

      obj = JSON.parse(body)

      if obj.is_a?(Array)
        obj.map(&RecursiveOpenStruct.method(:new))
      else
        RecursiveOpenStruct.new(obj)
      end
    else
      raise "#{method} #{File.join(@endpoint.to_s, path)}: #{response.code} #{response.message}"
    end
  end

  def headers
    {
      'User-Agent'       => "DiscordBot (https://github.com/Resonious/resmaster, #{VERSION})",
      'Content-Type'     => 'application/json',
      # 'Content-Encoding' => 'gzip',
      'Accept'           => 'application/json',
      'Accept-Encoding'  => 'gzip',
      'Authorization'    => "Bot #{@token}"
    }
  end

  def net_path(path)
    File.join(@endpoint.path, path)
  end
end
