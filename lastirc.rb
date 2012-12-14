require 'cinch'
require 'cinch/plugins/basic_ctcp'
require 'configru'
require 'lastfm'
require 'pstore'
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
  option :pstore, String, 'lastirc.pstore'
end

class LastIRC
  include Cinch::Plugin

  set :prefix, Regexp.escape(Configru.irc.prefix)

  def initialize(*args)
    super(*args)

    @pstore = PStore.new(Configru.pstore)
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

  def pstore_get(m)
    @pstore.transaction(true) { @pstore[m.user.nick] } || m.user.nick
  end

  match /assoc(?:iate)?\? ?([^ ]+)?$/, method: :command_associateq
  match /assoc(?:iate)? ?([^ ]+)?$/, method: :command_associate

  match /last ?(-\d+)? ?([^ ]+)?$/, method: :command_last
  match /plays ?([^ ]+)?$/, method: :command_plays

  match /compare ?([^ ]+)? ([^ ]+)$/, method: :command_compare
  match /bestfriend ?([^ ]+)?$/, method: :command_bestfriend

  match /hipster ?(-[^ ]+)? ?([^ ]+)?$/, method: :command_hipster
  match /hipsterbattle (-[^ ]+)? ?(.+)/, method: :command_hipsterbattle

  match /topartist ?(-[^ ]+)? ?([^ ]+)?$/, method: :command_topartist
  match /topalbum ?(-[^ ]+)? ?([^ ]+)?$/, method: :command_topalbum
  match /toptrack ?(-[^ ]+)? ?([^ ]+)?$/, method: :command_toptrack

  match /help ?([^ ]+)?$/, method: :command_help

  def command_associate(m, user)
    if user
      @pstore.transaction { @pstore[m.user.nick] = user }
      m.reply("Your nick is now associated with the Last.fm account '#{user}'", true)
    else
      assoc = @pstore.transaction(true) { @pstore[m.user.nick] }
      if assoc
        m.reply("Your nick is associated with the Last.fm account '#{assoc}'", true)
      else
        m.reply("Your nick is not associated with a Last.fm account", true)
      end
    end
  end

  def command_associateq(m, nick)
    return command_associate(m, nil) unless nick
    assoc = @pstore.transaction(true) { @pstore[nick] }
    if assoc
      m.reply("#{nick} is associated with the Last.fm account '#{assoc}'")
    else
      m.reply("#{nick} is not associated with a Last.fm account")
    end
  end

  def format_track(track)
    s = ""
    s << track['artist']['content']
    s << ' - '
    s << track['name']
    s << ' [' << track['album']['content'] << ']' if track['album']['content']
    s << ' ('
    if track['nowplaying']
      s << 'Listening now'
    else
      s << Time.at(track['date']['uts'].to_i).ago_in_words
    end
    s << ')'
    s 
  end

  def command_last(m, index, user)
    user = pstore_get(m) unless user
    index = index ? -index.to_i : 1
    api_transaction(m) do
      track = @lastfm.user.get_recent_tracks(user)[index - 1]
      m.reply("#{user}: #{format_track(track)}")
    end
  end

  def command_plays(m, user)
    user = pstore_get(m) unless user
    api_transaction(m) do
      info = @lastfm.user.get_info(user)
      registered = Time.at(info['registered']['unixtime'].to_i)
      m.reply("#{user}: #{info['playcount']} plays since #{registered.strftime('%d %b %Y')}")
    end
  end

  def command_compare(m, user1, user2)
    user1 = pstore_get(m) unless user1
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
    user = pstore_get(m) unless user
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

  def calculate_hipster(m, period, user)
    api_transaction(m) do
      # TODO: Expire this cache?
      @chart_top ||= @lastfm.chart.get_top_artists(:limit => 0).map {|x| x['name'] }
      user_top = @lastfm.user.get_top_artists(:user => user, :period => period)
      total_weight = user_top.map {|x| x['playcount'].to_i }.reduce(:+)
      score = 0
      user_top.each do |artist|
        score += artist['playcount'].to_i if @chart_top.include?(artist['name'])
      end
      score.to_f / total_weight * 100.0
    end
  end

  def command_hipster(m, period, user)
    user = pstore_get(m) unless user
    hipster = calculate_hipster(m, period ? period[1..-1] : 'overall' , user)
    m.reply("#{user} is #{'%0.2f' % hipster}% mainstream")
  end

  def command_hipsterbattle(m, period, users)
    hipsters = {}
    users.split(' ').each do |user|
      hipsters[user] = calculate_hipster(m, period ? period[1..-1] : 'overall', user)
    end
    winner, score = hipsters.min {|a, b| a[1] <=> b[1] }
    m.reply("#{winner} wins with #{'%0.2f' % score}% mainstream")
  end

  def command_topartist(m, period, user)
    user = pstore_get(m) unless user
    top = @lastfm.user.get_top_artists(:user => user, :period => period ? period[1..-1] : 'overall', :limit => 1)
    m.reply("#{user}: #{top['name']} (#{top['playcount']} plays)")
  end

  def command_topalbum(m, period, user)
    user = pstore_get(m) unless user
    top = @lastfm.user.get_top_albums(:user => user, :period => period ? period[1..-1] : 'overall', :limit => 1)
    m.reply("#{user}: #{top['artist']['name']} - #{top['name']} (#{top['playcount']} plays)")
  end

  def command_toptrack(m, period, user)
    user = pstore_get(m) unless user
    top = @lastfm.user.get_top_tracks(:user => user, :period => period ? period[1..-1] : 'overall', :limit => 1)
    m.reply("#{user}: #{top['artist']['name']} - #{top['name']} (#{top['playcount']} plays)")
  end

  Help = {
    assoc: "{user}: Associate user with your nick",
    assoc?: "[nick]: Retrieve user associated with nick",
    last: "[-index] [user]: Retrieve user's last scrobble",
    plays: "[user]: Retrieve user's scrobble count",
    compare: "[user] {user}: Compare music taste of two users",
    bestfriend: "[user]: Determine which of user's friends has most similar taste",
    hipster: "[-period] [user]: Calculate how mainstream user's taste is",
    hipsterbattle: "[-period] {users...}: Calculate which user has least mainstream taste",
    topartist: "[-period] [user]: Retrieve user's most played artist",
    topalbum: "[-period] [user]: Retrieve user's most played album",
    toptrack: "[-period] [user]: Retrieve user's most played track"
  }

  def command_help(m, command)
    if command
      m.reply("#{command} #{Help[command.to_sym]}", true) if Help.include?(command.to_sym)
    else
      m.reply("commands: #{Help.keys.join(', ')}", true)
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
