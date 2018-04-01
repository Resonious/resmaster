require 'net/http'
require 'json'
require 'base64'
require 'websocket-client-simple'
require 'resolv-replace.rb'

module Permissions
  CREATE_INSTANT_INVITE = 0x0000001 # Allows creating of instant invites
  KICK_MEMBERS = 0x0000002 # Allows kicking members
  BAN_MEMBERS = 0x0000004 # Allows banning members
  MANAGE_ROLES = 0x0000008 # Allows management and editing of roles
  MANAGE_CHANNELS = 0x0000010 # Allows management and editing of channels
  MANAGE_GUILD = 0x0000020 # Allows management and editing of the guild
  MANAGE_SERVER = MANAGE_GUILD
  READ_MESSAGES = 0x0000400 # Allows reading messages in a channel. The channel will not appear for users without this permission
  SEND_MESSAGES = 0x0000800 # Allows for sending messages in a channel.
  SEND_TTS_MESSAGES = 0x0001000 # Allows for sending of /tts messages
  MANAGE_MESSAGES = 0x0002000 # Allows for deleting messages
  EMBED_LINKS = 0x0004000 # Links sent by this user will be auto-embedded
  ATTACH_FILES = 0x0008000 # Allows for uploading images and files
  READ_MESSAGE_HISTORY = 0x0010000 # Allows for reading messages history
  MENTION_EVERYONE = 0x0020000 # Allows for using the @everyone tag to notify all users in a channel
  CONNECT = 0x0100000 # Allows for joining of a voice channel
  SPEAK = 0x0200000 # Allows for speaking in a voice channel
  MUTE_MEMBERS = 0x0400000 # Allows for muting members in a voice channel
  DEAFEN_MEMBERS = 0x0800000 # Allows for deafening of members in a voice channel
  MOVE_MEMBERS = 0x1000000 # Allows for moving of members between voice channels
  USE_VAD = 0x2000000 # Allows for using voice-activity-detection in a voice channel
end

class RStruct
  def self.wrap(x)
    return x unless x.is_a?(Hash)
    new(x.to_h)
  end

  def def_val(key, val)
    @values[key] = val.is_a?(RStruct) ? val.instance_variable_get(:@values) : val
    define_singleton_method(key) { val }
    define_singleton_method("#{key}?") { !!val }
  end

  def initialize(hash)
    @values = {}

    hash.each do |key, value|
      if value.is_a?(Array)
        def_val key, value.map { |v| RStruct.wrap(v) }
      else
        def_val key, RStruct.wrap(value)
      end
    end
  end

  def inspect(pretty = false)
    if pretty
      JSON.pretty_generate @values
    else
      @values.to_json
    end
  end

  def to_h
    @values
  end

  def to_s
    inspect
  end

  def to_str
    inspect
  end
end

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
  invalid_session: 9,
  gateway_hello: 10,
  heartbeat_ack: 11
}
OPCODE_NAMES = OPCODES.map(&:reverse).to_h

CHANNEL_TYPES = {
  GUILD_TEXT: 0,
  DM: 1,
  GUILD_VOICE: 2,
  GROUP_DM: 3,
  GUILD_CATEGORY: 4
}

VERSION = "0.0.2"

class Bot
  attr_reader :token
  attr_reader :sequence
  attr_reader :websocket
  attr_reader :heartbeat_thread

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

    log_in
    true
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

  def get(path, data = nil)
    full_path = net_path(path)

    if data
      full_path << "?"
      full_path << URI.encode_www_form(data)
    end
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

  def mention(user)
    user_id = user.is_a?(RStruct) ? user.id : user
    "<@#{user_id}>"
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
          # Ugh
          bot.log_out
          bot.log_in
          next
        end

        begin
          message = RStruct.new(JSON.parse compressed_msg.data)
        rescue StandardError => e
          puts "ERROR PARSING GATEWAY MESSAGE: #{e.class.name} #{e.message}"
          puts e.backtrace.join("\n")
          next
        end

        case message.op
        when OPCODES[:gateway_hello]
          bot.start_gateway_heartbeat(message.d.heartbeat_interval / 1000)

        when OPCODES[:heartbeat_ack]
          # cool

        when OPCODES[:dispatch]
          begin
            bot.gateway_handle_event(message)
          rescue StandardError => e
            puts "#{e.class} raised during #{message.t}: #{e.message}"
            e.backtrace.each do |line|
              puts line
            end
          end

        else
          puts "Unhandled opcode #{message.op} (full message: #{message.to_h})"
        end
      end

      ws.on :error do |e|
        puts "ERROR! #{e}"
        puts "The bot was logged out due to the previous error"
        bot.log_out
      end

      ws.on :close do |e|
        puts "Gateway connection closed: #{e}"
        bot.log_out
      end
    end
  end

  def log_out
    @heartbeat_thread.kill if @heartbeat_thread
    @heartbeat_thread = nil
    @websocket.close if @websocket
    @websocket = nil
  rescue
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
    @heartbeat_thread = Thread.new do
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

  def wait_for_throttle!
    if @rl_remaining <= 0
      sleep_time = Time.at(@rl_reset) - Time.now

      if sleep_time > 0
        yield sleep_time if block_given?
        sleep sleep_time
      end

      true
    end
    false
  end

  protected

  # Used for HTTP stuff (not WS)
  def process_data(data)
    data.to_json
    # gzip data.to_json
  end

  def return_valid_body(method, path, response)
    @rl_limit = response.header['x-ratelimit-limit'].to_i
    @rl_remaining = response.header['x-ratelimit-remaining'].to_i
    @rl_reset = response.header['x-ratelimit-reset'].to_i

    if response.code.to_i == 200
      if response.header['content-encoding'] && response.header['content-encoding'] =~ /gzip/
        body = gunzip response.body
      else
        body = response.body
      end

      obj = JSON.parse(body)

      if obj.is_a?(Array)
        obj.map(&RStruct.method(:new))
      else
        RStruct.new(obj)
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
