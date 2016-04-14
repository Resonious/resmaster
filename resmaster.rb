require_relative 'api'
require 'marky_markov'

RESMASTER_TOKEN = IO.read('resmaster-token.txt')

class Resmaster < Bot
  attr_reader :user
  attr_reader :ready_event
  attr_reader :chain

  def initialize
    connect(DISCORD_API, RESMASTER_TOKEN)
    log_in

    @user = get '/users/@me'
    @chain = {}
    at_exit { @chain.each_value(&:save_dictionary!) }
    at_exit { log_out }

    @print_event_names = true
    @print_heartbeats  = false
  end

  def chain_for(user)
    @chain[user.id] ||= MarkyMarkov::Dictionary.new(user.id)
  end

  def record_sentence(data)
    puts "Recording #{data.content.inspect} from #{data.author.username}"
    message = data.content.dup
    message << '.' unless message =~ /[\.\?!]$/
    chain_for(data.author).parse_string message
  end

  def say(d, msg)
    channel_id = d.respond_to?(:channel_id) ? d.channel_id : d
    post "/channels/#{channel_id}/messages", { content: msg }
  end

  def respond_to_mention(data)
    puts "Got #{data.content.inspect} from #{data.author.username}"

    case data.content.downcase
    when /<@#{@user.id}>\s+imitate\s+(<@\d+>)/
      data.mentions.each do |user|
        next if user.id == @user.id

        chain = chain_for(user)
        if chain.dictionary.empty?
          say data, "Sorry #{data.author.username}, I don't know #{user.username} very well."
        else
          say data, chain.generate_n_sentences(Random.rand(3) + 1)
        end
      end

    else
      case Random.rand(5)
      when 0 then say data, "Hey."
      when 1 then say data, "Yo, #{mention data.author}."
      when 2 then say data, "What's up, #{mention data.author}?"
      when 3 then say data, "Hi, #{mention data.author}."
      when 4 then say data, "Hello, #{mention data.author}."
      else        say data, "Hello there, #{mention data.author}."
      end
    end
  end

  on_event :READY do |data|
    puts "Ready! #{data.inspect}"
    @ready_event = data
  end

  on_event :MESSAGE_CREATE do |data|
    next if data.author.id == @user.id

    if data.mentions.map(&:id).include?(@user.id)
      respond_to_mention(data)
    else
      record_sentence(data)
    end
  end
end
