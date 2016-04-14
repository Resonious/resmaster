require_relative 'api'
require 'marky_markov'

RESMASTER_TOKEN = IO.read('resmaster-token.txt')

class Resmaster < Bot
  attr_reader :user
  attr_reader :ready_event
  attr_reader :chain
  attr_reader :last_channel_id
  attr_reader :last_guild_channel_id

  def initialize
    connect(DISCORD_API, RESMASTER_TOKEN)

    @user = get '/users/@me'
    @chain = {}
    at_exit { save and log_out }

    @print_event_names = false
    @print_heartbeats  = false
  end

  def save
    @chain.each_value(&:save_dictionary!)
  end

  def chain_for(user)
    @chain[user.id] ||= MarkyMarkov::Dictionary.new(user.id)
  end

  def read_up(channel_id, amount)
    count = 0
    messages = get "/channels/#{channel_id}/messages", { limit: 100 }

    loop do
      count += 1
      messages.each do |message|
        record_sentence(message)
      end

      break if messages.size < 100
      break if count >= amount
      messages = get "/channels/#{channel_id}/messages", { limit: 100, before: messages.last.id }
    end
  end

  def record_sentence(data)
    message = data.content.dup
    message << '.' unless message =~ /[\.\?!]$/
    if /https?:\/\/\S+/ =~ message
      return
    end
    chain_for(data.author).parse_string message
  end

  def say(d_or_msg, msg = nil)
    if msg == nil
      msg = d_or_msg
      channel_id = @last_channel_id
    else
      channel_id = d_or_msg.respond_to?(:channel_id) ? d_or_msg.channel_id : d_or_msg
    end
    if channel_id.nil?
      raise "Could not chat - no channel specified"
    end

    post "/channels/#{channel_id}/messages", { content: msg }
  end

  def respond_to_mention(data, channel)
    puts "Got #{data.content.inspect} from #{data.author.username}"

    if channel.is_private?
      imitate_regex = /imitate\s+(<@\d+>)/
      execute_regex = /execute\s+`/m
    else
      imitate_regex = /<@#{@user.id}>\s+imitate\s+(<@\d+>)/
      execute_regex = /<@#{@user.id}>\s+execute\s+`/m
    end

    case data.content.downcase
    # "@Resmaster imitate @someone"
    when imitate_regex
      data.mentions.each do |user|
        next if user.id == @user.id

        chain = chain_for(user)
        if chain.dictionary.size < 15
          say data, "Sorry #{data.author.username}, I don't know #{user.username} very well."
        else
          unless /(?<count>\d+)\s+sentences/ =~ data.content.downcase
            count = Random.rand(3) + 1
          end

          say @last_guild_channel_id || @last_channel_id, chain.generate_n_sentences(count.to_i)
        end
      end

    # "@Resmaster execute `puts "code here"`"
    when execute_regex
      if data.author.username == 'Resonious' || data.author.username == 'Dinkyman'
        /```(?<code>.+)```/ =~ data.content or /`(?<code>.+)`/ =~ data.content
        begin
          msg = data
          instance_eval(code)
        rescue StandardError => e
          say data, "#{mention data.author} #{e}: #{e.message}"
        end
      else
        case Random.rand(4)
        when 0 then say data, "#{mention data.author} I'm not gonna execute code for you."
        when 1 then say data, "#{mention data.author} No."
        when 2 then say data, "#{mention data.author} Nuh uh."
        when 3 then say data, "#{mention data.author} I do not trust you."
        else        say data, "#{mention data.author} Would rather not."
        end
      end

    else
      case Random.rand(5)
      when 0 then say data, "Hey."
      when 1 then say data, "Yo, #{mention data.author}."
      when 2 then say data, "What's up, #{mention data.author}?"
      when 3 then say data, "Hi, #{mention data.author}."
      when 4 then say data, "Hello, #{mention data.author}."
      else        say data, "Screw you, #{mention data.author}."
      end
    end
  end

  on_event :READY do |data|
    puts "Ready! #{data.inspect}"
    @ready_event = data
  end

  on_event :MESSAGE_CREATE do |data|
    next if data.author.id == @user.id

    channel = get "/channels/#{data.channel_id}"
    @last_channel_id       = data.channel_id
    @last_guild_channel_id = data.channel_id unless channel.is_private?

    if channel.is_private? || data.mentions.map(&:id).include?(@user.id)
      respond_to_mention(data, channel)
    else
      record_sentence(data)
    end
  end
end

if $0 != 'irb'
  r = Resmaster.new
  sleep 5
  r.heartbeat_thread.join
end
