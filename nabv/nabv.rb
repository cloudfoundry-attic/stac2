# Copyright (c) 2009-2013 VMware, Inc.
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
require 'uuidtools'
require 'mongo'
require 'ap'
require 'cfoundry'

APPS = 'apps.yml'

$log = Logger.new(STDOUT)
#$log.level = Logger::DEBUG
$log.level = Logger::INFO
#$log.level = Logger::WARN

$vcap_services = JSON.parse(ENV['VCAP_SERVICES']) if ENV['VCAP_SERVICES']
$vcap_app = JSON.parse(ENV['VCAP_APPLICATION']) if ENV['VCAP_APPLICATION']
$log.info "vcs: #{$vcap_services.pretty_inspect}"
$log.debug "vca: #{$vcap_app.pretty_inspect}"

$app_host_ip = $vcap_app['host']
$app_host_port = $vcap_app['port']
$app_name = $vcap_app['name']
$app_host = $vcap_app['uris'][0]
$instance_id = $vcap_app['instance_id']
$instance_index = $vcap_app['instance_index']
$active_worker_id = "nabv::#{$instance_index}"

index = $app_host.index "#{$app_name}."
if index == 0
  $nab_base_domain = $app_host.gsub("#{$app_name}.",'')
  $naburl = "http://nabh.#{$nab_base_domain}"
  $nabvurl = "http://nabv.#{$nab_base_domain}"
else
  $log.debug("exiting an: #{$app_name}, au: #{$app_host}, index: #{index} of #{$app_name}., nb: #{$nab_base_domain}")
  exit
end
$log.debug("an: #{$app_name}, au: #{$app_host}, index: #{index} of #{$app_name}., nb: #{$nab_base_domain}")

# compute the path to the config directory
# then load the workload definitions, and then the
# the configs for the various clouds
$basepath = File.expand_path(File.join(File.dirname(__FILE__), '.'))
$log.debug "basepath #{$basepath}"
apps_file = File.expand_path("config/#{APPS}", "#{__FILE__}/..")
config_path = File.expand_path("config", "#{__FILE__}/..")
$log.debug "config_path #{config_path}"

# at this point we know
# $nab_base_domain: when asking for work from nab, we use this host (nabv and nab are co-located)
# next step is to enumerate and load all of the configured hosts. This is done by
# enumerating *.config.yml where * will expand to cloudfoundry.com.config.yml, appcloud06.dev.mozycloud.com, etc.
begin

  # config structure is:
  # config/
  # config/apps.yml - system wide app definitions
  # config/clouds/*.config.yml - per-cloud configuration (mail, domains, max clients, users, etc.)

  # load the apps definitions
  apps = File.open(apps_file) do |f|
    YAML.load(f)
  end
  $apps = apps['apps']
  # merge into the new $workloads structure
  $workloads = {'apps' => $apps, 'workloads' => {}}

  # enumerate the config_path for *.config.yml and then
  # load those configs
  $configs = {}
  Dir.glob("#{config_path}/clouds/*.config.yml") do |fn|
    #$log.debug "fn: #{fn}"
    config = YAML.load(File.open(fn))
    #$log.debug config.pretty_inspect
    shortname = config['shortname']
    if $configs[shortname]
      STDERR.puts "configuration collision. #{fn} references existing shortname #{shortname}"
      exit
    end
    $configs[shortname] = config
    if $nab_base_domain == config['app_domain']
      $default_cloud = $configs[shortname]
      #$log.debug "default cloud: #{config['app_domain']}"
    end
  end
rescue => e
  STDERR.puts "Could not read the configuration file: #{e}"
  exit
end

if $default_cloud == nil
  STDERR.puts "failed top determine default cloud"
  exit
end

$NOT_AUTHORIZED = {"status" => "not authorized"}.to_json
redis = nil
redis = $vcap_services['redis'][0] if $vcap_services['redis']
redis = $vcap_services['redis-2.2'][0] if !redis && $vcap_services['redis-2.2']

redis_conf = {:host => redis['credentials']['hostname'],
              :port => redis['credentials']['port'],
              :password => redis['credentials']['password']}
$redis_t3 = Redis.new redis_conf

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
#$log.debug("mongo: #{mongo.pretty_inspect}, mc: #{mc.pretty_inspect}")
$mongo = Mongo::Connection.new(mc[:connection_string])
#$log.debug("mongo(1a): Mongo::Connection.new(#{mc[:connection_string]}) --> #{$mongo.pretty_inspect}")
$mongodb = $mongo.db(mc[:db])


# now that we know which clouds we are configured for
# populate the list of clouds, and also the scenario
# list into redis
$work_queues = []
def reconfig(do_v2)
  $work_queues = []
  $configs.each_key do |cloud|
    $redis_t3.sadd("vmc::clouds", cloud)
    $work_queues << "vmc::#{cloud}::cmd_queue"
  end
  $log.debug "wq: #{$work_queues.pretty_inspect}"

  # load workloads from mongo, then inject into redis
  workloads = $mongodb.collection("workloads")
  $workloads['workloads'] = {} if workloads

  # kill the workload hash and then reload from mongo
  $redis_t3.del("vmc::workloadhash")
  workloads.find.each do |wldoc|
    #$log.debug("rc(0): wldoc['__key__'] => #{wldoc['__key__']}, wldoc => #{wldoc.pretty_inspect}")
    $workloads['workloads'][wldoc['__key__']] = wldoc
    wlkey = wldoc['__key__']
    $redis_t3.sadd("vmc::workloads", wlkey)
    $redis_t3.hset("vmc::workloadhash", wlkey, wldoc.to_json)
  end

  $redis_t3.set("vmc::naburl", $naburl)
  $redis_t3.set("vmc::nabvurl", $nabvurl)
  $log.debug("reconfig: #{do_v2}, instance: #{$vcap_app['instance_index']}")
  if do_v2
    setup_constants($default_cloud)
  end
end

def setup_constants(cloud)
  v2 = {}
  target = "http://#{cloud['cc_target']}"
  v2['target'] = target
  begin
    $log.debug("sv2: login #{target} #{cloud['users'][0]['name']}/#{cloud['users'][0]['password']}")
    cfclient = CFoundry::Client.new(target)
    cfclient.login({:username => cloud['users'][0]['name'], :password => cloud['users'][0]['password']})
  rescue Exception => e
    puts "exception during login #{target} #{cloud['users'][0]['name']}/#{cloud['users'][0]['password']}"
    puts e.pretty_inspect
  end

  if $default_cloud['mode'] == 'v2'
    # cache cloud's space and org guid
    v2['org'] = {}
    v2['org']['name'] = cloud['org']
    v2['space'] = {}
    v2['space']['name'] = cloud['space']
    cfclient.current_organization = cfclient.organization_by_name(v2['org']['name'])
    cfclient.current_space = cfclient.space_by_name(v2['space']['name'])
    v2['org']['id'] = cfclient.current_organization.guid
    v2['space']['id'] = cfclient.current_space.guid
  end

  # cache frameworks and runtimes
  v2['frameworks'] = {}
  frameworks = cfclient.frameworks
  frameworks.each do |fw|
    $log.debug("sec: fw == #{fw.name}")
    v2['frameworks'][fw.name] = fw.name
    v2['frameworks'][fw.name] = fw.guid if $default_cloud['mode'] == 'v2'
  end
  v2['runtimes'] = {}
  runtimes = cfclient.runtimes
  runtimes.each do |rt|
    $log.debug("sec: rt == #{rt.name}")
    v2['runtimes'][rt.name] = rt.name
    v2['runtimes'][rt.name] = rt.guid if $default_cloud['mode'] == 'v2'
  end

  # cache service plans
  if $default_cloud['mode'] == 'v2'
    v2['services'] = {}
    services = cfclient.services
    services.each do |s|
      $log.debug("s: #{s.label}, #{s.provider}, #{s.version}")
      s.service_plans.each do |sp|
        $log.debug("sp: #{sp.name}, #{sp.guid}")
        v2['services'][s.label] = sp.guid if sp.name.casecmp("D100") == 0
        v2['services']["#{s.label}:::#{sp.name}"] = sp.guid
      end
    end
  end
  $log.debug("sv2: v2-s #{v2.pretty_inspect}")
  $redis_t3.set("vmc::#{cloud['shortname']}::v2cache", v2.to_json)
end
reconfig($vcap_app['instance_index'] == 0)

# clear various http proxy's
# since most are set incorrectly and we use transparent if any in prod/staging
ENV.delete('http_proxy')
ENV.delete('https_proxy')
ENV.delete('HTTP_PROXY')
ENV.delete('HTTPS_PROXY')

$log.debug "Time.now #{Time.now}"
$log.debug "Time.now.utc #{Time.now.utc}"

# If we are running within the cloud, clean up configs.
#FileUtils.rm_rf(config_path) if ENV['VCAP_APPLICATION']

#use Rack::Auth::Basic do |username, password|
#  [username, password] == [config['auth']['user'], config['auth']['pass']]
#end

# link to our libraries
$:.unshift(File.join(File.dirname(__FILE__), 'lib'))
require 'nabv/vmcworker'
require 'nabv/vmcworkitem'

# message threads
$workers = 2
$workers.times do |thread_index|
  Thread.new do
    begin
      redis = Redis.new redis_conf
      redis_t2 = Redis.new redis_conf

      # always remove worker from the cloud's active workers set
      # this handles the case where a worker is executed while active
      # in this case, when the hm restarts the worker, we need to clear out the
      # old record since that worker was executed and the new worker is taking its place
      worker_id = "#{$active_worker_id}::#{thread_index}"
      key = "vmc::#{$default_cloud['shortname']}::active_workers"
      x = redis.srem(key, worker_id)
      $log.debug("#{x} = redis.srem(#{key}, #{worker_id}")

      VmcWorker.run($work_queues, $apps, redis, redis_t2, worker_id)
    rescue Exception => e
      $log.warn "*** FATAL UNHANDLED EXCEPTION ***"
      $log.warn "e: #{e.inspect}"
      $log.warn "at@ #{e.backtrace.join("\n")}"
      $log.warn "wq: #{$work_queues}"
      retry
    end
  end
end

# Web pages here...

get '/' do
  VmcWorker.index
end

get '/cleanall' do
  cmd = {}
  workitem = VmcWorkItem.new(cmd, $redis_t3, $apps, "#{$active_worker_id}::000")
  rv = workitem.enumApps(:true)
  rv.to_json
end

get '/cwl' do
  reconfig true
  rv = {}
  rv['clouds'] = $configs
  rv['workloads'] = $workloads
  rv['naburl'] = $naburl
  rv['nabvurl'] = $nabvurl
  rv['default_cloud'] =  $default_cloud['shortname']
  rv.to_json
end

get '/env' do
  res = ''
  ENV.each do |k, v|
    res << "#{k}: #{v}<br/>"
  end
  res
end


get '/reset' do
  VmcWorker.reset
end
