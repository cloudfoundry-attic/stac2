# Copyright (c) 2009-2013 VMware, Inc.
require 'net/http'
require 'net/https'
require 'uri'

helpers do

  # -------------------------- new code for stac2 fe ----------------------
  # -------------------------- core api helpers ---------------------------
  def reset_cloud(cloud)
    keys = $redis.keys "vmc::#{cloud}::*"
    $log.debug "keys: #{keys.pretty_inspect}"
    keys.each do |k|
      $redis.del k
    end
    collection = "stac2__#{cloud}__exceptions"
    c = $mongodb.collection(collection)
    c.drop()
    keys
  end

  def get_action_stats(cloud, since)

    # raw result scheme
    loadkey = "vmc::#{cloud}::load"
    rv = {
      :timestamp => Time.now.tv_sec,
      :action_counts => {},
      :stats => {},
    }
    load = $redis.get(loadkey)
    rv[:load] = JSON.parse(load) if load

    # organized by "row" where the key is the action
    as = {}
    $actions.each do |data|
      k = data[0]
      v = data[1]
      as[k] = {:k => k, :action_name => v}
    end

    scarf_keys = [
      # vmc
      { :key => "vmc::#{cloud}::actions::action_set", :column => 'action_count'},
      { :key => "vmc::#{cloud}::actions::time_50", :column => 'action_count_50'},
      { :key => "vmc::#{cloud}::actions::time_50_100", :column => 'action_count_50_100'},
      { :key => "vmc::#{cloud}::actions::time_100_200", :column => 'action_count_100_200'},
      { :key => "vmc::#{cloud}::actions::time_200_400", :column => 'action_count_200_400'},
      { :key => "vmc::#{cloud}::actions::time_400_1s", :column => 'action_count_400_1s'},
      { :key => "vmc::#{cloud}::actions::time_1s_2s", :column => 'action_count_1s_2s'},
      { :key => "vmc::#{cloud}::actions::time_2s_3s", :column => 'action_count_2s_3s'},
      { :key => "vmc::#{cloud}::actions::time_3s", :column => 'action_count_3s'},
      { :key => "vmc::#{cloud}::actions::time_average", :column => 'action_count_avg'},
      { :key => "vmc::#{cloud}::actions::fail_set", :column => 'action_count_err'},

      # http counts
      { :key => "vmc::#{cloud}::http::action_set", :column => 'action_count'},
      { :key => "vmc::#{cloud}::http::time_50", :column => 'action_count_50'},
      { :key => "vmc::#{cloud}::http::time_50_100", :column => 'action_count_50_100'},
      { :key => "vmc::#{cloud}::http::time_100_200", :column => 'action_count_100_200'},
      { :key => "vmc::#{cloud}::http::time_200_400", :column => 'action_count_200_400'},
      { :key => "vmc::#{cloud}::http::time_400_1s", :column => 'action_count_400_1s'},
      { :key => "vmc::#{cloud}::http::time_1s", :column => 'action_count_1s'},
    ]

    scarf_keys.each do |item|
      #$log.debug("scarfing: #{item.pretty_inspect}")
      s = get_zset(item[:key])
      #$log.debug("scarfing: get_zset --> #{s.pretty_inspect}")
      set_row(as, s, item[:column]) if s
    end

    # http response status row
    s = get_zset("vmc::#{cloud}::http::response_status_bucket_set")
    if s.length > 0
      as['http-status'] = {
        :k => 'http-status'
      }
      s.each_index do |i|
        k = "resp_#{s[i][:member]}"
        v = s[i][:score]
        as['http-status'][k] = v
      end
    else
      as['http-status'] = {
        :k => 'http-status'
      }
    end

    # inject count into http_response row
    if as['http-status']
      # inject action_count if present
      if as['http-req'] && as['http-req']['action_count']
        as['http-status']['action_count'] = as['http-req']['action_count']
      else
        as['http-status']['action_count'] = 0
      end
    end

    # and now, record count properties as % of action_count
    as.each do |k,v|
      # for instances,
      # k = 'login'
      # v = '{ 'action_count', action_count_1s, etc.}
      if v['action_count']
        ac = v['action_count'].to_f
        percents = {}
        v.each do |kk,vv|
          # now whip through the properties, and as needed, add a % column
          next if kk == :k || kk ==:action_name || kk == 'rate_1s' || kk == 'action_count'
          percent = sprintf("%.2f\%",((vv.to_f/ac) * 100.0))
          #$log.debug("(vv/ac)*100.0 -> #{vv.to_f}/#{ac}*100.0 --> #{((vv.to_f/ac) * 100.0)} #{percent}")
          percents["#{kk}_percent"] = percent
        end
        percents.each do |kk,vv|
          v[kk] = vv
        end
        #$log.debug("getsstats-v: #{v.pretty_inspect}")
        #$log.debug("getsstats-p: #{percents.pretty_inspect}")
        # now add in the properties we just compute
      end
    end
    rv[:action_counts] = as
    #$log.debug("get_stats: rv[:action_counts] --> #{rv[:action_counts].pretty_inspect}")

    # add in random singleton stats
    rv[:stats]['pending_workitems'] = $redis.llen "vmc::#{cloud}::cmd_queue"

    boot_time = $redis.get "vmc::#{cloud}::boot_time"
    if boot_time
      rv[:stats]['boot_time'] = boot_time

      bt = boot_time.to_i
      now = Time.now.tv_sec
      uptime = now - bt
      rv[:stats]['uptime'] = uptime
      rv[:stats]['uptime_string'] = uptime_string(uptime)['clock']
    else
      rv[:stats]['boot_time'] = Time.now.tv_sec
      rv[:stats]['uptime'] = 0
      rv[:stats]['uptime_string'] = ""
    end

    # capture number of active workers
    rv[:stats]['vmc_active_workers'] = $redis.scard "vmc::#{cloud}::active_workers"

    # capture the current rate
    tvn = Time.now.tv_sec
    one_s_cur_tv = tvn
    one_s_prev_tv = tvn - 1

    # grab cc action rate
    one_s_prev_key = "vmc::#{cloud}::rate_1s::#{one_s_prev_tv}"
    one_s_prev = $redis.get(one_s_prev_key).to_i
    if one_s_prev
      rv[:stats]['action_rate'] = one_s_prev
    else
      rv[:stats]['action_rate'] = 0
    end

    # grab http request rate
    one_s_prev_key = "vmc::#{cloud}::http_rate_1s::#{one_s_prev_tv}"
    one_s_prev = $redis.get(one_s_prev_key).to_i
    if one_s_prev
      rv[:stats]['http_rate'] = one_s_prev
    else
      rv[:stats]['http_rate'] = 0
    end

    # inject rate into status row if present
    if rv[:action_counts]['http-status']
      rv[:action_counts]['http-status']['rate_1s'] = one_s_prev
    end

    # grab the exception log from mongo, scoped to the since passed by the caller
    rv[:elog] = []
    collection = "stac2__#{cloud}__exceptions"
    c = $mongodb.collection(collection)
    $log.debug("gas:er3 since: #{since}")
    c.find({"tv" => {"$gt" => since}}, {:limit => 10, :sort => ['tv', :ascending]}).each do |exception_record|
      $log.debug("gas:er since: #{since}, tv #{exception_record['tv']}, #{exception_record.pretty_inspect}")
      rv[:elog] << exception_record
    end
    $log.debug("get_action_stats: #{rv.pretty_inspect}")
    $laststats = rv
    rv
  end

  def capture_and_send_stats(cloud, tag)

    # capture the status used to drive the UI
    # as well as the config/settings
    stats = get_action_stats(params[:cloud])
    settings = $cloudsandworkloads
    mailstats = {
      :stats => stats,
      :settings => settings,
      :timestamp => Time.now.tv_sec,
      :tag => tag
    }

    annotated = annotate_for_display(cloud, mailstats)
    $log.debug("astats: #{annotated.pretty_inspect}")

    # configure an email client
    config = nil

    config = $cloudsandworkloads["clouds"][cloud]['email'] if $cloudsandworkloads["clouds"][cloud]['email'] != nil
    #$log.debug("cwl4: #{config.pretty_inspect}") if config != nil

    halt 401,"cloud: #{cloud} not configured for email" if config == nil
    mailer = MailLib.new(config)

    # html body
    haml_engine_html = Haml::Engine.new(File.read($email_html_template))
    #$log.debug("he: #{haml_engine_html.pretty_inspect}")
    #$log.debug("hep: #{$email_html_template}")

    #x = {:s => stats, :c => settings, :cloud => cloud}
    #html_body = haml_engine_html.render(Object.new, :s => x)
    html_body = haml_engine_html.render(Object.new, {:as => annotated, :s => stats, :c => settings})
    #html_body = "<body style='font-size:16px;'>hi</body>"

    # plain body
    #haml_engine_plain = Haml::Engine.new(File.read($email_plain_template))
    #body = haml_engine_plain.render(Object.new, :s => stats, :c => settings, :cloud => cloud)
    body = "plain old body"

    subject = "stac2 activity_report - #{cloud}-#{tag}-#{mailstats[:timestamp]}"

    # compute recipient based on configuration
    # if there is no recipient for a tag
    # the mail is suppressed, effectively turning
    # off that channel
    to = mailer.resolve_to(tag, false)
    halt 401,"cloud: #{cloud}, no recipient enabled for: #{tag}" if to == nil

    # json file is timestamp and cloud
    t = Time.now()
    json_file = "#{cloud}-#{tag}-#{t.strftime('%FT%T+00:00_stats_dump')}"

    mailer.send(to, subject, body, html_body,
                {"#{json_file}.json" => "#{annotated.to_json}"})

    # return value is json attachment we tried to deliver
    # makes this a dual use API, returns the data and also
    # fires a send email event
    if params[:ashtml]
      $log.debug("send: ashtml is set, params: #{params.pretty_inspect}")
      return html_body
    else
      return annotated
    end
  end

  def annotate_for_display(cloud, s)
    as = {:raw => s, :cloud => cloud}

    # produce a selection of actions that have errors
    errors = select_and_sort(s[:stats][:action_counts], 'action_count_err')
    top_actions = select_and_sort(s[:stats][:action_counts], 'action_count')
    slow_actions = select_and_sort(s[:stats][:action_counts], 'action_count_1s')

    # hand grab http http-req stats and http-status
    http_actions = []
    http_actions << ["http-req", s[:stats][:action_counts]['http-req']] if s[:stats][:action_counts]['http-req']
    http_actions << ["http-status", s[:stats][:action_counts]['http-status']] if s[:stats][:action_counts]['http-status']

    as[:errors] = errors
    as[:top_actions] = top_actions
    as[:slow_actions] = slow_actions
    as[:http_actions] = http_actions
    as
  end

  # note, this returns and array of form [ [key, value], ...]
  def select_and_sort(actions, key, opts={})
    selection = actions.select do |k,v|
      #$log.debug("as1: #{k}, #{v.pretty_inspect}")
      v[key] != nil
    end
    sorted = selection.sort do |a,b|
      # a,b are arrays, index 0 is the key name, 1 is the value
      va = a[1]
      vb = b[1]
      #$log.debug("sort: a: #{va[key].to_i} <=> b: #{vb[key].to_i} ==> #{va[key].to_i <=> vb[key].to_i}")
      -1 * (va[key].to_i <=> vb[key].to_i)
    end
    sorted
  end

  # reset all stats from redis
  def reset_redis
    $redis.flushall
  end


  # -------------------------- random support methods ---------------------------

  def get_zset(k)
    setdata = $redis.zrange(k, 0, -1, :with_scores => true)
    #$log.debug("gzs: #{k} --> #{setdata.pretty_inspect}")
    sd = []
    i = 0
    total = 0
    while i < setdata.length
      stathash = { :member => setdata[i], :score => setdata[i+1]}
      sd << stathash
      i += 2
    end
    sd
  end

  # transform the column values into rows of data
  # e.g., in redis we keep scores/sets by operation (push, etc.)
  # for display, we show operations a row at a time with all related data
  # as part of that display row.
  def set_row(as, set, column)
    #$log.debug "set_row, as: #{as.pretty_inspect}"
    #$log.debug "set_row, set: #{set.pretty_inspect}"
    #$log.debug "set_row, column: #{column}"
    set.each_index do |i|
      k = set[i][:member]
      #$log.debug "sr_loop i: #{i}, k: #{k}"
      # auto-drop columns like pause, etc.
      as[k][column] = set[i][:score] if as[k]
    end
    #$log.debug "set_row: post: #{column}, #{as.pretty_inspect}"
  end

  #
  # force load clouds and workloads
  def load_clouds_and_workloads
    if $cloudsandworkloads == nil
      nabvurl = $redis2.get "vmc::nabvurl"
      if nabvurl == nil || !nabvurl.start_with?('http://nab')
        $log.info("load_clouds_and_workloads: missing nabvurl, recreating using $default_if_null_nabvurl: #{$default_if_null_nabvurl}")
        nabvurl = $default_if_null_nabvurl
      end
      nabvurl = nabvurl + "/cwl"
      httpclient = HTTPClient.new()
      response = httpclient.get nabvurl
      $log.debug "gcwl: #{nabvurl}, --> #{response.status}"
      $log.debug "gcwl: #{response.pretty_inspect}"

      halt response.status, 'nabv is not running' if response.status != 200
      $cloudsandworkloads = JSON.parse(response.body)
      $log.debug("cwl-loaded: #{$cloudsandworkloads.pretty_inspect}")
    end
  end

  # -------------------------- OLD FROM AS ----------------------------
  # token and password utility functions
  def create_token (username)
    # 7-day token
    token = [ username, (Time.new.gmtime + 7 * 24 * 60 * 60).to_i ]
    token << token_hash(token)
    t = Marshal.dump(token).unpack('H*')[0]
    # puts "returning t: #{t}"
    t
  end

  def token_hash(token)
    HMAC::SHA1.new($config['token_key']).update("#{token[0]}#{token[1]}").digest
  end

  def logged_in?()
    return nil unless request.cookies['autoscale']

    token = request.cookies['autoscale']
    return nil if token == "bummer"

    # puts "in logged_in, got token string : #{token.inspect}"
    token = Marshal.load([token].pack('H*'))

    if token_hash(token) == token[2]
      if (token[1] - Time.new.gmtime.to_i) > 0
        t = token if $config['username'] == token[0]
        #puts "login success #{t}, #{token}"
        return t
      end
    end
    return nil
  end

  $SECONDS_PER_DAY = 86000

  # compute rate value given t0, t1, delta
  def rate(t0, t1, timespan)
    rv = 0
    rv = (t1-t0)/timespan if timespan > 0
    rv
  end

  def uptime_string(delta)
    num_seconds = delta.to_i
    days = num_seconds / (60 * 60 * 24);
    num_seconds -= days * (60 * 60 * 24);
    hours = num_seconds / (60 * 60);
    num_seconds -= hours * (60 * 60);
    minutes = num_seconds / 60;
    num_seconds -= minutes * 60;

    rv = { 'full' => "#{days}d:#{hours}h:#{minutes}m:#{num_seconds}s"}
    clockstyle = ""
    clockstyle += "#{days}d " if days && days.to_i > 0
    clockstyle += sprintf("%02d:%02d:%02d", hours, minutes, num_seconds)
    rv['clock'] = clockstyle
    rv
  end

  def pretty_units(size, prec=1)
    return 'NA' unless size
    return "#{size}" if size < 1024
    return sprintf("%.#{prec}fK", size/1024.0) if size < (1024*1024)
    return sprintf("%.#{prec}fM", size/(1024.0*1024.0)) if size < (1024*1024*1024)
    return sprintf("%.#{prec}fG", size/(1024.0*1024.0*1024.0))
  end

  # payload generator
  def generate_payload(size = 0)
    size = rand(64)+1 if size == 0
    charset = %w{ 2 3 4 6 7 9 A C D E F G H J K L M N P Q R T V W X Y Z}
    (0...size).map{ charset.to_a[rand(charset.size)] }.join
  end

  # poor man's password
  def protected!
    response['WWW-Authenticate'] = %(Basic realm="Testing HTTP Auth") and throw(:halt, [401, "Not authorized\n"]) and return unless authorized?
  end

  def authorized?
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    @auth.provided? && @auth.basic? && @auth.credentials &&
    @auth.credentials == ['stac2', 'ilikestac2']
  end

end

