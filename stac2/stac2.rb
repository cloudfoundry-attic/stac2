
# Copyright (c) 2009-2011 VMware, Inc.
# note: remember to run bundler package and bundler install
require 'rubygems'
require 'bundler/setup'
require 'sinatra'
require 'redis'
require 'haml'
require 'json/pure'
require 'pp'
require 'parsedate'
require 'time'
require 'logger'
require 'hmac-sha1'
require 'httpclient'
require 'pony'
require 'mongo'

# staging and shard should double size the ui
$base_ui = 4
$large_ui = 8
$ui_table = {
    'cf01.qa.las01.vcsops.com' => $large_ui,
    'cf01.las2.us1.vcsops.com' => $large_ui
}

begin
  $log = Logger.new(STDOUT)
  #$log.level = Logger::DEBUG
  $log.level = Logger::INFO
  #$log.level = Logger::WARN

  $vcap_services = JSON.parse(ENV['VCAP_SERVICES']) if ENV['VCAP_SERVICES']
  $vcap_app = JSON.parse(ENV['VCAP_APPLICATION']) if ENV['VCAP_APPLICATION']
  $log.debug "vcs: #{$vcap_services.pretty_inspect}"
  $log.debug "vca: #{$vcap_app.pretty_inspect}"

  $app_name = $vcap_app['name']
  $app_host = $vcap_app['uris'][0]
  index = $app_host.index "#{$app_name}."
  if index == 0
    $stac2_base_domain = $app_host.gsub("#{$app_name}.",'')
    $default_if_null_naburl = "http://nabh.#{$stac2_base_domain}"
    $default_if_null_nabvurl = "http://nabv.#{$stac2_base_domain}"
  else
    $log.debug("exiting an: #{$app_name}, au: #{$app_host}, index: #{index} of #{$app_name}.")
    exit
  end
  $log.info("$default_if_null_naburl: #{$default_if_null_naburl}")
  $log.info("$default_if_null_nabvurl: #{$default_if_null_nabvurl}")

  $NOT_AUTHORIZED = {"status" => "not authorized"}.to_json

  # redis
  if $vcap_services['redis-2.2']
    redis = $vcap_services['redis-2.2'][0]
  else
    redis = $vcap_services['redis'][0]
  end
  redis_conf = {:host => redis['credentials']['hostname'],
                :port => redis['credentials']['port'],
                :password => redis['credentials']['password']}
  $redis = Redis.new redis_conf
  $redis2 = Redis.new redis_conf
  $redis3 = Redis.new redis_conf
  $redis4 = Redis.new redis_conf

  # mongo
  mongo = nil
  mongo = $vcap_services['mongodb'][0] if $vcap_services['mongodb']
  mongo = $vcap_services['mongodb-2.0'][0] if !mongo && $vcap_services['mongodb-2.0']
  mongo = $vcap_services['mongodb-1.8'][0] if !mongo && $vcap_services['mongodb-1.8']

  mc = {:host => mongo['credentials']['host'],
                :port => mongo['credentials']['port'],
                :db => mongo['credentials']['db'],
                :username => mongo['credentials']['username'],
                :password => mongo['credentials']['password']}
  mc[:connection_string] = "mongodb://#{mc[:username]}:#{mc[:password]}@#{mc[:host]}:#{mc[:port]}/#{mc[:db]}"
  $log.info("mongo: #{mongo.pretty_inspect}, mc: #{mc.pretty_inspect}")
  $mongo = Mongo::Connection.new(mc[:connection_string])
  $log.debug("mongo(1a): Mongo::Connection.new(#{mc[:connection_string]}) --> #{$mongo.pretty_inspect}")
  $mongodb = $mongo.db(mc[:db])

  #$mongo2 = Mongo::Connection.new(mc[:host], mc[:port])
  #$log.info("mongo(1b): Mongo::Connection.new(#{mc[:host]}, #{mc[:port]}) --> #{$mongo2.pretty_inspect}")

  #$redis = Redis.new redis_conf
  #$redis2 = Redis.new redis_conf
  #$redis3 = Redis.new redis_conf


  # If we are running within the cloud, clean up configs.
  #FileUtils.rm_rf(config_path) if ENV['VCAP_APPLICATION']

  #use Rack::Auth::Basic do |username, password|
  #  [username, password] == [config['auth']['user'], config['auth']['pass']]
  #end

  $basepath = File.expand_path(File.join(File.dirname(__FILE__), '.'))
  $config_path = File.expand_path("config", "#{__FILE__}/..")
  $log.debug "config_path #{$config_path}"
  $email_html_template = File.expand_path("views/email.haml", "#{__FILE__}/..")
  $email_plain_template = File.expand_path("views/email_plain.haml", "#{__FILE__}/..")

  # link to our libraries
  $:.unshift(File.join(File.dirname(__FILE__), 'lib'))
  require 'stac2/helpers'
  require 'stac2/maillib'
  require 'stac2/workload'

  $clouds = $redis.smembers("vmc::clouds")
  $naburl = $redis.get("vmc::naburl")
  $log.debug "s2: clouds: #{$clouds.pretty_inspect}"

  # these are the actions that we display
  # note, pause is not in the list, etc.
  # the purpose of this indirection is to enable
  # display names in the UI and also to establish ordering
  # independent of what we see in the various accounting redis sets
  $actions = [
    ['info','vmc info'],
    ['login', 'vmc login'],
    ['apps', 'vmc apps'],
    ['create_app', 'vmc push'],
    ['update_app', 'vmc update'],
    ['delete_app', 'vmc delete'],
    ['start_app', 'vmc start'],
    ['stop_app', 'vmc stop'],
    ['app_info', 'vmc stats'],
    ['user_services', 'vmc services'],
    ['system_services', 'vmc info --services'],
    ['create_service', 'vmc create-service'],
    ['delete_service', 'vmc delete-service'],
    ['bind_service', 'vmc bind-service'],
    ['create_space', 'vmc create-space'],
    ['delete_space', 'vmc delete-space'],
    ['http-req', 'http request'],
  ]

  # Web pages here...

  $cloudsandworkloads = nil
  $loadcloud = nil
rescue Exception => e
  puts "* * * FATAL UNHANDLED EXCEPTION ***"
  puts "e: #{e.inspect}"
  puts "at@ #{e.backtrace.join("\n")}"
end


# render html homepage, deliver js code
get '/' do
  headers['Cache-Control'] = 'no-store'
  load_clouds_and_workloads
  $ui_size = $base_ui
  if $ui_table[$stac2_base_domain]
    $ui_size = $ui_table[$stac2_base_domain]
  end
  $lights = 24 * $ui_size
  $log.debug("rendering with ui_size of #{$ui_size}")
  haml :index
end

# render in detail a single exception log record
# note, this is only available on log records that
# include a cflog array whose size is > 1
get '/showlog' do
  halt 400 if !params[:oid]
  halt 400 if !params[:cloud]
  headers['Cache-Control'] = 'no-store'
  collection = "stac2__#{params[:cloud]}__exceptions"
  l = nil
  c = $mongodb.collection(collection)
  c.find({"_id" => BSON::ObjectId(params[:oid])}).each do |exception_record|
    l = exception_record
    $log.info("find, id => #{params[:oid]} #{exception_record.pretty_inspect}")
  end
  if l
    if params[:json]
      content_type 'application/json'
      l.to_json
    else
      dlurl = "/showlog?oid=#{params[:oid]}&cloud=#{params[:cloud]}&json=1"
      haml :showlog, :locals => {:l => l, :dlurl => dlurl}
    end
  else
    redirect '/'
  end
end

# render workloads editor/loader
get '/workloads' do
  #halt 400 if !params[:cloud]
  headers['Cache-Control'] = 'no-store'
  wl = Workload.new()

  if params[:reload]
    wl.reload_from_static_path
    # force nabv to re-read from mongo
    $cloudsandworkloads = nil
    load_clouds_and_workloads
  else
    wl.select
  end
  $wl = wl
  haml :workloads
end

# delete workload
get '/workloads/delete' do
  headers['Cache-Control'] = 'no-store'
  #halt 400 if !params[:cloud]
  halt 400 if !params[:key]
  wl = Workload.new()
  $log.info("wld(0): #{params[:key]}")

  wl.delete params[:key]
  wl.select
  $cloudsandworkloads = nil
  load_clouds_and_workloads
  {:status => 'OK'}.to_json
end

# load workload
post '/workloads/upload' do
  headers['Cache-Control'] = 'no-store'
  $log.info("wul(0): #{params.pretty_inspect}")

  unless params["wl_file"] &&
         (tmpfile = params["wl_file"][:tempfile]) &&
         (name = params["wl_file"][:filename])
    @error = "No file selected"
    $log.info("wul(0a): no file selected: #{params.pretty_inspect}")
    return 'no file'
  end

  # parse the content as a yaml workload
  wl_yml = YAML.load(params["wl_file"][:tempfile])
  $log.info("wul(1a): #{wl_yml.pretty_inspect}")

  # delete any existing entry at that slot
  wl = Workload.new()
  wl.delete params["wl_file"][:filename]
  wl.upload params["wl_file"][:filename], wl_yml
  redirect '/workloads'
end


get '/cl' do
  headers['Cache-Control'] = 'no-store'
  $cloudsandworkloads = nil
  load_clouds_and_workloads
  $cloudsandworkloads.to_json
end

# start scenario
# return json stats for specified cloud
# - cloud=selected-cloud
# -
get '/run-load' do
  headers['Cache-Control'] = 'no-store'
  halt 400 if !params[:cloud]
  halt 400 if !params[:c]
  halt 400 if !params[:n]
  halt 400 if !params[:wl]
  halt 400 if !params[:cmax]
  halt 400 if !params[:load]
  halt 400 if !params[:host]
  halt 400 if !params[:start]

  key = "vmc::#{params[:cloud]}::load"
  v = {
    'tv' => Time.now.tv_sec,
    'cloud' => params[:cloud],
    'c' => params[:c],
    'n' => params[:n],
    'wl' => params[:wl],
    'cmax' => params[:cmax],
    'load' => params[:load],
    'host' => params[:host],
    'start' => params[:start],
  }
  vj = v.to_json

  $loadcloud = v['cloud']

  $log.debug("run-load: setting $loadcloud = #{$loadcloud}")

  # see if value is present
  #if so, and its in the on state, then ignore offs, that are not more that two seconds out
  previous_vj = $redis.get key
  if previous_vj
    previous_v = JSON.parse(previous_vj);
    if previous_v['start'] == 'true'
      # ignore requests for ~>2s past last start
      tv_now = Time.now.tv_sec
      tv_start = previous_v['tv'].to_i
      if tv_now <= tv_start + 1
        # we are within 2s of last start so drop this on the floor
        $log.debug("run-load: writing against a started load within 1s of start, ignore")
        return vj
      end
    end
  end
  $redis.set key, vj
  vj
end

# load runner thread
$runrate = 1
$lograte = 10 # 10  # log every N seconds

# at ~4k logs, think 14M/hr, 353M/day at 1s
# at 1/10th sampling think 1.4M/hr, 35.3M/day
# max_records 10,000 * 4k = max log data of 40M
$max_log_bytes = 48*(1024*1024)
$max_log_records = 10000 # 1 day of operation sampled every 10s

# exception log, 1000 records, 4k record size
$max_elog_records = 1000
$max_elog_bytes = $max_elog_records*(4*1024)

$run_tv = 0

Thread.new do
  begin
    logpass = 0
    while true do
      # sleep for RUNRATE
      $log.debug("run-thread(0): tv: #{Time.now.tv_sec}, runrate = #{$runrate}, $loadcloud = #{$loadcloud}")
      sleep $runrate
      $log.debug("run-thread(1): tv: #{Time.now.tv_sec}")
      if $loadcloud
        key =  "vmc::#{$loadcloud}::load"
        vj = $redis3.get key
        if vj
          v = JSON.parse(vj)
          $log.debug("run-thread(2a): vj: #{vj}")
          $log.debug("run-thread(2b): v: #{v.pretty_inspect}")

          # if we have enabled load, then
          if v['start'] == 'true'
            # if the running timestamp is less than the current timestamp
            # then switch loads (drain both workqueues, then poke nabh)
            if $run_tv < v['tv'].to_i
              $run_tv = v['tv'].to_i
              vmc_queue = "vmc::#{$loadcloud}::cmd_queue"
              http_queue = "http::#{$loadcloud}::cmd_queue"
              $redis3.del vmc_queue
              $redis3.del http_queue
            end

            #
            url = "#{v['host']}/vmc"
            httpclient = HTTPClient.new()
            args = {
              'cloud' => v['cloud'],
              'c' => v['c'],
              'n' => v['n'],
              'wl' => v['wl'],
              'cmax' => v['cmax']
            }
            response = httpclient.get url, args
            $log.debug "run-thread(3): #{url}, #{args.pretty_inspect}, --> #{response.status}"

            logpass = logpass + 1
            if logpass >= $lograte
              c = $mongodb.collection("logs")
              records = c.count()
              $log.debug("c0_0: record count for c == #{records}");
              if records == 0
                $mongodb.create_collection("logs", :capped => true, :size => $max_log_bytes, :max => $max_log_records)
                c = $mongodb.collection("logs")
                $log.debug("c0_1: c #{c.pretty_inspect}")
              else
                c = $mongodb.collection("logs")
              end
              c.insert($laststats) if $laststats
              logpass = 0
            end
          else
            logpass = 0
            vmc_queue = "vmc::#{$loadcloud}::cmd_queue"
            http_queue = "http::#{$loadcloud}::cmd_queue"
            $redis3.del vmc_queue
            $redis3.del http_queue
          end
        end
      end
    end
  rescue Exception => e
    logpass = 0
    $log.warn "*** FATAL UNHANDLED EXCEPTION ***"
    $log.warn "e: #{e.inspect}"
    $log.warn "at@ #{e.backtrace.join("\n")}"
    retry
  end
end

# exception logger thread
Thread.new do
  begin
    timeout = 1
    while true do

      # adjust based on cloud changes, so do this in the loop
      if $cloudsandworkloads
        queues = []
        $cloudsandworkloads['clouds'].each_key do |k|
          queues << "vmc::#{k}::exception_queue"
        end
        $log.debug "blpop(#{queues.pretty_inspect}, timeout)"
        queue, msg = $redis4.blpop(*[queues, 0].flatten)
        $log.debug "blpop => #{queue}, #{msg.inspect}"
        if queue && msg
          # msg is an exception record.
          # extract the cloud name from the message and use this
          # to target the collection
          elog = JSON.parse(msg)
          cloud = elog['cloud']
          collection_name = "stac2__#{cloud}__exceptions"

          # this is terrible logic. need to unify the collection setup
          c = $mongodb.collection(collection_name)
          records = c.count()
          $log.debug("c0_0: record count for c == #{records}");
          if records == 0
            # also set an index on this on the tv prop
            $mongodb.create_collection(collection_name, :capped => true, :size => $max_elog_bytes, :max => $max_elog_records)
            c = $mongodb.collection(collection_name)
            c.create_index([['tv', Mongo::DESCENDING]])
            $log.debug("c0_1: c #{c.pretty_inspect}")
          else
            c = $mongodb.collection(collection_name)
          end
          c.insert(elog)
        else
          $log.warn("timeout")
        end
      else
        sleep timeout
      end
    end
  rescue Exception => e
    logpass = 0
    $log.warn "*** FATAL UNHANDLED EXCEPTION ***"
    $log.warn "e: #{e.inspect}"
    $log.warn "at@ #{e.backtrace.join("\n")}"
    retry
  end
end

# return json stats for specified cloud
get '/ss2' do
  halt 400 if !params[:cloud]
  since = 0 if !params[:since]
  since = params[:since].to_i if params[:since]
  $log.debug("gas:er2 since: #{since}")
  s = get_action_stats(params[:cloud], since)
  content_type 'application/json'
  s.to_json
end

# capture status and send in email
get '/ems' do
  halt 400 if !params[:cloud]
  load_clouds_and_workloads
  s = capture_and_send_stats(params[:cloud], 'webapi')
  if params[:ashtml]
    s
  else
    s.to_json
  end
end

get '/cleanapps' do
  halt 400 if !params[:cloud]
  nabvurl = $redis.get "vmc::nabvurl"
  nabvurl = nabvurl + "/cleanall"
  httpclient = HTTPClient.new()
  args = {'cloud' => params[:cloud]}
  response = httpclient.get nabvurl, args
  $log.debug "enumApps: #{nabvurl}, #{args.pretty_inspect}, --> #{response.status}"
  $log.debug "enumApps: #{response.pretty_inspect}"
  response.body
end

# reset specified cloud
get '/rs' do
  halt 400 if !params[:cloud]
  s = reset_cloud(params[:cloud])
  content_type 'application/json'
  s.to_json
end