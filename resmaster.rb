require_relative 'api'
require 'marky_markov'

RESMASTER_TOKEN = IO.read('resmaster-token.txt').chomp.strip

class Resmaster < Bot
  attr_reader :user
  attr_reader :ready_event
  attr_reader :chain
  attr_reader :last_channel_id
  attr_reader :last_guild_channel_id
  attr_reader :last_message_by_requester
  attr_reader :last_message_for_user

  GeneratedMessage = Struct.new(:user, :message) do
    def to_s
      "**#{user.username}:** #{message}"
    end
  end

  def initialize
    connect(DISCORD_API, RESMASTER_TOKEN)

    @user = get '/users/@me'
    @chain = {}
    @last_message_by_requester = {}
    @last_message_for_user = {}
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

  def read_all(channel_id)
    s=0
    read_up(channel_id, 1000000000000) { |m| s += m.size; puts "read #{s}" }
    say 'done'
  end

  def read_up(channel_id, amount)
    count = 0
    messages = get "/channels/#{channel_id}/messages", { limit: 100 }

    loop do
      count += 1
      messages.each do |message|
        record_sentence(message)
      end

      yield messages if block_given?

      break if messages.size < 100
      break if count >= amount

      wait_for_throttle!
      messages = get "/channels/#{channel_id}/messages", { limit: 100, before: messages.last.id }
    end

    count
  end

  def record_sentence(data)
    message = data.content.dup
    message << '.' unless message =~ /[\.\?!]$/
    if /https?:\/\/\S+/ =~ message
      return
    end
    if /\[[\d:PMA]+\]/ =~ message
      return
    end
    if /Like . Reply/ =~ message
      return
    end
    if / - \d\d\/\d\d\/\d\d\d\d/ =~ message
      return
    end
    chain_for(data.author).parse_string message
  end

  def say(*args)
    if args.last.is_a?(Hash)
      options = args.pop
    else
      options = {}
    end

    case args.size
    when 1 
      message = args.first
      channel_id = @last_channel_id
    when 2
      message = args.last
      channel_id = args.first
    else
      raise ArgumentError, "Wrong number of arguments #{args.size} instead of 1 or 2 (+ options)"
    end

    if channel_id.respond_to?(:channel_id)
      channel_id = channel_id.channel_id
    end

    post "/channels/#{channel_id}/messages", { content: message.to_s, tts: !!options[:tts] }
  end

  def respond_to_mention(data, channel)
    puts "Got #{data.content.inspect} from #{data.author.username}"

    if channel.type == CHANNEL_TYPES[:DM]
      imitate_regex = /imitate\s+@\w+/
      execute_regex = /execute\s+`/m
      repeat_regex = /(repeat|say)\s+(last|message|that|again|for)/
      help_regex = /help/
    else
      imitate_regex = /<@#{@user.id}>\s+imitate\s+(<@[!\d]+>)/
      execute_regex = /<@#{@user.id}>\s+execute\s+`/m
      repeat_regex = /<@#{@user.id}>\s+(repeat|say)\s+(last|message|that|again|for)/
      help_regex = /<@#{@user.id}>\s+help/
    end

    case data.content.downcase
    # "@Resmaster imitate @someone"
    when imitate_regex
      users = data.mentions
      if channel.type == CHANNEL_TYPES[:DM]
        data.content.scan(/@\w+/).each do |match|
          begin
            if match == @user.id
              say "-_- that me"
            end

            users << get("/users/#{match.gsub('@', '')}")
          rescue => e
            say e.message
          end
        end
      end

      if users.empty?
        say "Couldn't find anyone fitting your criteria."
        return
      end

      users.each do |user|
        next if user.id == @user.id

        chain = chain_for(user)
        if chain.dictionary.size < 10
          say data, "Sorry #{data.author.username}, I don't know #{user.username} very well."
        else
          unless /(?<count>\d+)\s+sentences/ =~ data.content.downcase
            count = Random.rand(3) + 1
          end

          in_guild = /\s+in guild/ =~ data.content.downcase
          tts      = /\s+tts/ =~ data.content.downcase

          channel_id = in_guild ? @last_guild_id : @last_channel_id
          generated_message = GeneratedMessage.new(user, chain.generate_n_sentences(count.to_i))

          last_message_by_requester[data.author.id] = generated_message
          last_message_for_user[user.id] = generated_message

          say channel_id, generated_message.message, tts: tts
        end
      end

    # "@Resmaster repeat last message"
    # "@Resmaster repeat for @whoever"
    when repeat_regex
      users = data.mentions.reject { |u| u.id == @user.id }

      if users.empty?
        # Say last message requested by author
        last_message = last_message_by_requester[data.author.id]

        if last_message.nil?
          say data, "You have not asked me to imitate anyone, #{mention data.author}."
        else
          say data, last_message
        end
      else
        # Say last imitation of given user(s)
        users.each do |user|
          last_message = last_message_for_user[user.id]

          if last_message.nil?
            say data, "I've got nothing from **#{user.username}**."
          else
            say data, last_message
          end
        end
      end

    when help_regex
      say data, "Here's what I can do:"
      topics = []
      topics << "`@Resmaster imitate @SomeoneElse`\nI'll imitate them to the best of my ability."
      topics << "`@Resmaster say again`\nI'll repeat the last imitation you asked me for."
      topics << "`@Resmaster repeat for @SomeoneElse`\nI'll repeat my last imitation of @SomeoneElse."
      say topics.join("\n\n")
      say data, "You can DM me this stuff, too. If you want me to imitate someone in a DM, "+
        "you'll need their ID. Send me `imitate @12345` -- where '1235' is their user ID. "+
        "Then you can go back to the server and have me say it again for everyone's viewing pleasure."

    # "@Resmaster execute `puts "code here"`"
    # TODO security lollllll anyone can change username
    when execute_regex
      admins = ['Resonious', 'dinkyman']
      if admins.include?(data.author.username)
        /```(?<code>.+)```/ =~ data.content or /`(?<code>.+)`/ =~ data.content
        begin
          puts "EXECUTING #{code}"
          instance_eval(code)
          puts "FINISHED EXECUTING #{code}"
        rescue StandardError => e
          say data, "#{mention data.author} #{e}: #{e.message}"
        end
      else
        case Random.rand(5)
        when 0 then say data, "#{mention data.author} I'm not gonna execute code for you."
        when 1 then say data, "#{mention data.author} No."
        when 2 then say data, "#{mention data.author} Nuh uh."
        when 3 then say data, "#{mention data.author} I do not trust you."
        when 4 then say data, "Nice try, #{mention data.author}."
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

  on_event :MESSAGE_CREATE, :MESSAGE_EDIT do |data|
    next if data.author.id == @user.id

    channel = get "/channels/#{data.channel_id}"
    #puts JSON.pretty_generate channel.to_h
    @last_channel_id       = data.channel_id
    @last_guild_channel_id = data.channel_id if channel.type == CHANNEL_TYPES[:GUILD_TEXT]

    if channel.type == CHANNEL_TYPES[:DM] || data.mentions.map(&:id).include?(@user.id)
      respond_to_mention(data, channel)
    else
      record_sentence(data)
    end
  end
end

if $0 != 'irb'
  attempts = 1000000000000
  (1..attempts).each do |i|
    begin
      r = Resmaster.new
      loop do
        sleep 5
        if r.heartbeat_thread.nil?
          puts "haertbeat is dead. long live resmaster"
          exit 1
        end
        r.heartbeat_thread.join
        sleep 1
        r.log_out unless r.websocket.nil?
        puts "Re-logging in"
        r.log_in
      end

      break
    rescue Errno::ENETUNREACH => e
      sleep_time = attempts - i + 1
      puts "#{e.class} #{e.message}"
      puts "Crashed! Recovering in #{sleep_time} seconds."
      sleep sleep_time
    end
  end
end
