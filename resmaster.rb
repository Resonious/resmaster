require_relative 'api'

class Resmaster
  include Api

  attr_reader :user

  def initialize
    connect(DISCORD_API, RESMASTER_TOKEN)
    @user = get '/users/@me'
  end

  def upload_avatar(filename)
    patch '/users/@me', { avatar: avatar_file(filename) }
  end
end
