require_relative 'api'
require 'marky_markov'

RESMASTER_TOKEN = IO.read('resmaster-token.txt')

class Resmaster < Bot
  attr_reader :user
  attr_reader :ready_event
  attr_reader :chain

  def initialize
    connect(DISCORD_API, RESMASTER_TOKEN)

    @user = get '/users/@me'
    @chain = {}

    @print_event_names = true
    @print_heartbeats  = false
  end

  at_exit { @chain.each_value(&:save_dictionary!) if @chain }
  at_exit { puts "exiting" }

  def upload_avatar(filename)
    patch '/users/@me', { avatar: avatar_file(filename) }
  end

  def chain_for(user)
    @chain[user.id] ||= MarkyMarkov::Dictionary.new(user.id)
  end

  def record_sentence(data)
    message = data.content.dup
    message << '.' unless message =~ /\.$/
    chain_for(data.author).parse_string message
  end

  def respond_to_mention(data)
    puts "got #{data.content.inspect}"

    post "/channels/#{data.channel_id}/messages", {
      content: "Hello, @#{data.author.username}"
    }
  end

  on_event :READY do |data|
    puts "Ready! #{data.inspect}"
    @ready_event = data
  end

  on_event :MESSAGE_CREATE do |data|
    if data.mentions.map(&:id).include?(@user.id)
      respond_to_mention(data)
    else
      record_sentence(data)
    end
  end
end

if (ARGV.nil? || !ARGV[0].include?('irb') rescue false)
  resmaster = Resmaster.new
  resmaster.log_in
  sleep 5
  resmaster.heartbeat_thread.join if resmaster.heartbeat_thread
end
