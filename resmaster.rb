require_relative 'api'

RESMASTER_TOKEN = IO.read('resmaster-token.txt')

class Resmaster < Bot
  attr_reader :user
  attr_reader :ready_event

  def initialize
    connect(DISCORD_API, RESMASTER_TOKEN)

    @user = get '/users/@me'

    @print_event_names = true
    @print_heartbeats  = false
  end

  def upload_avatar(filename)
    patch '/users/@me', { avatar: avatar_file(filename) }
  end

  on_event :READY do |data|
    puts "Ready! #{data.inspect}"
    @ready_event = data
  end

  on_event :MESSAGE_CREATE do |data|
    puts "#{data.author.username} says #{data.content}"
  end
end

resmaster = Resmaster.new
resmaster.log_in
resmaster.heartbeat_thread.join
