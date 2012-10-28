require 'cinch'
require 'cinch/plugins/basic_ctcp'
require 'configru'
require 'lastfm'
require 'time-lord'

Configru.load('lastirc.yml') do
  option_group :irc do
    option :nick, String, 'lastfm'
    option_required :server, String
    option :port, Fixnum, 6667
    option_array :channels, String
    option :prefix, String, '!'
  end
  option_group :lastfm do
    option_required :token, String
    option_required :secret, String
  end
end

class LastIRC
  include Cinch::Plugin

  set :prefix, Regexp.escape(Configru.irc.prefix)

  def initialize(*args)
    super(*args)

    @lastfm = Lastfm.new(Configru.lastfm.token, Configru.lastfm.secret)
  end

  def format_track(track)
    s = ""
    s << track['artist']['content']
    s << ' - '
    s << track['name']
    s << ' [' << track['album']['content'] << ']'
    s << ' (' << Time.at(track['date']['uts'].to_i).ago_in_words << ')'
    s 
  end

  match /last (.+)/, method: :command_last
  match /taste ([^ ]+) (.+)/, method: :command_taste

  def command_last(m, user)
    begin
      track = @lastfm.user.get_recent_tracks(user).first
      m.reply("#{user}: #{format_track(track)}")
    rescue Lastfm::ApiError => e
      m.reply("Last.fm error: #{e.message.strip}", true)
    end
  end

  def command_taste(m, user1, user2)
    begin
      compare = @lastfm.tasteometer.compare(:user, :user, user1, user2)
      score = compare['score'].to_f * 100
      m.reply("#{user1} and #{user2} have #{sprintf('%0.2f', score)}% similar taste")
    rescue Lastfm::ApiError => e
      m.reply("Last.fm error: #{e.message.strip}", true)
    end
  end
end

bot = Cinch::Bot.new do
  configure do |c|
    c.nick = Configru.irc.nick
    c.server = Configru.irc.server
    c.port = Configru.irc.port
    c.channels = Configru.irc.channels
    c.plugins.plugins = [Cinch::Plugins::BasicCTCP, LastIRC]
    c.plugins.options[Cinch::Plugins::BasicCTCP][:commands] = [:version, :time, :ping]
  end
end

bot.start
