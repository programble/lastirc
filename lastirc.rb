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

  def api_transaction(m, &block)
    begin
      block.call
    rescue Lastfm::ApiError => e
      m.reply("Last.fm error: #{e.message.strip}")
      raise
    end
  end

  def format_track(track)
    s = ""
    s << track['artist']['content']
    s << ' - '
    s << track['name']
    s << ' [' << track['album']['content'] << ']'
    s << ' ('
    if track['nowplaying']
      s << 'Listening now'
    else
      s << Time.at(track['date']['uts'].to_i).ago_in_words
    end
    s << ')'
    s 
  end

  match /last ([^ ]+)$/, method: :command_last
  match /plays ([^ ]+)$/, method: :command_plays
  match /compare ([^ ]+) ([^ ]+)$/, method: :command_compare
  match /bestfriend ([^ ]+)$/, method: :command_bestfriend
  match /hipster ([^ ]+)$/, method: :command_hipster
  match /hipsterbattle (.+)/, method: :command_hipsterbattle

  def command_last(m, user)
    api_transaction(m) do
      track = @lastfm.user.get_recent_tracks(user).first
      m.reply("#{user}: #{format_track(track)}")
    end
  end

  def command_plays(m, user)
    api_transaction(m) do
      info = @lastfm.user.get_info(user)
      registered = Time.at(info['registered']['unixtime'].to_i)
      m.reply("#{user}: #{info['playcount']} plays since #{registered.strftime('%d %b %Y')}")
    end
  end

  def command_compare(m, user1, user2)
    api_transaction(m) do
      compare = @lastfm.tasteometer.compare(:user, :user, user1, user2)
      score = compare['score'].to_f * 100
      matches = compare['artists']['matches'].to_i
      artists = compare['artists']['artist'].map {|x| x['name'] } if matches > 0

      s = ""
      s << "#{user1} and #{user2} have "
      s << '%0.2f' % score << '% similar taste '
      if matches > 0
        if matches > artists.length
          s << "(#{matches} artist#{matches == 1 ? '' : 's'} in common, including: "
        else
          s << "(#{matches} artist#{matches == 1 ? '' : 's'} in common: "
        end
        s << artists.join(', ')
        s << ')'
      end

      m.reply(s)
    end
  end

  def command_bestfriend(m, user)
    api_transaction(m) do
      friends = @lastfm.user.get_friends(user, :limit => 0).map {|x| x['name'] }
      scores = {}
      friends.each do |friend|
        scores[friend] = @lastfm.tasteometer.compare(:user, :user, user, friend)['score'].to_f
      end
      bestfriend = scores.max {|a, b| a[1] <=> b[1] }.first
      m.reply("#{user}'s best friend is #{bestfriend}")
    end
  end

  def command_hipster(m, user)
    api_transaction(m) do
      # TODO: Expire this cache?
      @chart_top ||= @lastfm.chart.get_top_artists(:limit => 0).map {|x| x['name'] }
      user_top = @lastfm.user.get_top_artists(user).map {|x| x['name'] }
      total_weight = user_top.length.downto(1).reduce(:+)
      score = 0
      weight = user_top.length
      user_top.each do |artist|
        score += weight if @chart_top.include?(artist)
        weight -= 1
      end
      hipster = score.to_f / total_weight * 100.0
      m.reply("#{user} is #{'%0.2f' % hipster}% mainstream")
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
