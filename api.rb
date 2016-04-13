require 'net/http'
require 'json'
require 'recursive_open_struct'
require 'base64'
require 'websocket-client-simple'

module OS
  def self.windows?
    (/cygwin|mswin|mingw|bccwin|wince|emx/ =~ RUBY_PLATFORM) != nil
  end

  def self.mac?
   (/darwin/ =~ RUBY_PLATFORM) != nil
  end

  def self.unix?
    !windows?
  end

  def self.linux?
    unix? and not mac?
  end

  def self.name
    if windows?
      'Windows'
    elsif mac?
      'Mac OSX'
    elsif linux?
      'Linux'
    elsif unix?
      'Unix'
    end
  end
end

DISCORD_API = 'https://discordapp.com/api'
OPCODES = {
  dispatch: 0,
  heartbeat: 1,
  identify: 2,
  status_update: 3,
  voice_state_update: 4,
  voice_server_ping: 5,
  resume: 6,
  reconnect: 7,
  request_guild_memebers: 8,
  invalid_session: 9
}
OPCODE_NAMES = OPCODES.map(&:reverse).to_h
VERSION = "0.0.1"

class Bot
  attr_reader :token
  attr_reader :sequence
  attr_reader :websocket

  class << self
    attr_accessor :event_handlers

    def on_event(*events, &block)
      self.event_handlers ||= {}

      events.each do |event|
        event_sym = event.to_sym
        event_handlers[event_sym] ||= []
        event_handlers[event_sym] << block
      end
    end
  end

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

  def log_in
    raise "Already logged in" unless @websocket.nil?

    @sequence = []
    bot = self
    @websocket = WebSocket::Client::Simple.connect gateway_url do |ws|
      ws.on :open do
        bot.gateway_send(
          :identify,

          token: "Bot #{bot.token}",
          properties: {
            '$os'               => OS.name,
            '$browser'          => bot.bot_name,
            '$device'           => bot.bot_name,
            '$referrer'         => '',
            '$referring_domain' => ''
          },
          compress: false,
          large_threshold: 50
        )
      end

      ws.on :message do |compressed_msg|
        if compressed_msg.data.empty?
          puts "Empty packet!? Are we still in?"
          next
        end
        message = RecursiveOpenStruct.new(JSON.parse compressed_msg.data)

        case message.op
        when OPCODES[:dispatch]
          if message.t == 'READY'
            bot.start_gateway_heartbeat(message.d.heartbeat_interval)
          end
          bot.gateway_handle_event(message)
        else
          puts "Unhandled opcode #{message.op} (full message: #{message.to_h})"
        end
      end

      ws.on :error do |e|
        puts "ERROR! #{e}"
        puts "The bot was logged out due to the previous error"
        bot.instance_variable_set :@websocket, nil
      end

      ws.on :close do |e|
        puts "Gateway connection closed: #{e}"
        bot.instance_variable_set :@websocket, nil
      end
    end
  end

  def gateway_send(opcode, data)
    raise "Must call log_in before using the gateway" if @websocket.nil?
    op = case opcode
    when Symbol then OPCODES[opcode]
    when String then OPCODES[opcode.to_sym]
    when Fixnum then opcode
    else OPCODES[opcode.to_sym]
    end

    if op.nil?
      puts "Bad opcode #{opcode.inspect}"
      return
    end

    puts "SENDING: #{OPCODE_NAMES[op]}"

    @websocket.send({
      op: op,
      d:  data
    }.to_json)
  end

  def gateway_handle_event(message)
    @sequence << message.s
    return if self.class.event_handlers.nil?
    handlers = self.class.event_handlers[message.t.to_sym] || []

    if @print_event_names
      puts "EVENT: #{message.t.inspect}"
    end

    handlers.each do |handler|
      instance_exec(message.d, &handler)
    end
  end

  def start_gateway_heartbeat(interval)
    Thread.new do
      if @print_heartbeats
        puts "HEARTBEAT begin"
      end

      loop do
        break if @websocket.nil?
        if !@websocket.open?
          puts "HEARTBEAT detected that the bot was logged out"
          @websocket = nil
          break
        end

        seq = @sequence.last || 0
        @websocket.send({
          op: 1,
          d: seq
        }.to_json)

        if @print_heartbeats
          puts "HEARTBEAT #{seq}"
        end
        sleep interval
      end

      if @print_heartbeats
        puts "HEARTBEAT end"
      end
    end
  end

  def bot_name
    "Resmaster Engine"
  end

  protected

  # Used for HTTP stuff (not WS)
  def process_data(data)
    data.to_json
    # gzip data.to_json
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
    @headers ||= {
      'User-Agent'       => "DiscordBot (https://github.com/Resonious/resmaster, #{VERSION})",
      'Content-Type'     => 'application/json',
      # 'Content-Encoding' => 'gzip', # Guess Discord API doesn't like zipped data!
      'Accept'           => 'application/json',
      'Accept-Encoding'  => 'gzip',
      'Authorization'    => "Bot #{@token}"
    }
  end

  def net_path(path)
    File.join(@endpoint.path, path)
  end
end
