# Copyright (c) 2009-2013 VMware, Inc.
require 'yaml'
require 'fileutils'
require 'cf'
require 'cfoundry'
require 'stringio'
require 'httpclient'

# this is a short term hack for v1 services
# already discussed with alex and ramnivas that
# either cfoundry needs to shield code from having to
# deal with this, or apps should load the various pieces
# dynamically. I'll do the later when I get on v2
V1_SERVICE_MAP = {
    'redis' => {
        'tier' => 'free',
        'version' => '2.2',
    },
    'mysql' => {
        'tier' => 'free',
        'version' => '5.1',
    },
    'postgresql' => {
        'tier' => 'free',
        'version' => '9.0',
    },
}

class CfWorkItem
  attr_reader :tv_start, :tv_end

  # init and timestamp a workitem
  # execution of a single workitem is a synchronous
  # and long running event
  def initialize(cmd, redis, apps, workerid)
    @fatal_abort = false
    @tv_start = nil
    @tv_end = nil
    @cmd = cmd
    @redis = redis
    @http_barrier_keys = []
    @http_barrier_stats = {}
    @active_worker_id = workerid
    assignWorkloads(apps)
  end

  def enumApps(delete_flag)
    $log.debug("ea(0): called with true") if delete_flag == true
    $log.debug("ea(0): called with !true") if delete_flag != true
    @cfclient = CFoundry::Client.new(@target)
    # enumerate the cloud's user array, validate the login, enum the apps
    users = @cloud['users']
    rv = {}
    rv['user:stats_raw'] = []

    users_with_apps = 0
    users_with_services = 0
    total_app_count = 0
    total_spaces_count = 0
    total_services_count = 0
    users.each do |u|
      $log.debug "ea(u): #{u.pretty_inspect}"
      @cfclient.login(u['name'], u['password'])
      login_extras
      v = {'name'=>u['name']}

      # enum the apps and services
      apps = @cfclient.apps
      services = @cfclient.service_instances

      # apps (and v2 routes)
      if apps && apps.length > 0
        users_with_apps += 1
        total_app_count += apps.length
        v['apps'] = apps
        apps.each do |theapp|
          $log.info("ea(1): deleting app: #{theapp.name}, #{u['name']}")
          if theapp.name.include?("appname-") || theapp.name.include?("caldecott")
            if @cloudmode == :v2
              theapp.routes.each do |r|
                $log.info("ea(2): deleting route #{r.host}, #{r.pretty_inspect}")
                theapp.remove_route(r) if delete_flag == true
                r.delete! if delete_flag == true
              end
            end
            theapp.delete! if delete_flag == true
          end
        end
      end

      # services
      if services && services.length > 0
        users_with_services += 1
        total_services_count += services.length
        services.each do |theservice|
          if theservice.name.include? "servicename-"
            $log.info("ea(3): deleting service: #{theservice.name}, #{u['name']}")
            theservice.delete! if delete_flag == true
          end
        end
      end

      # spaces
      if @cloudmode == :v2
        spaces = @cfclient.spaces
        if spaces and spaces.length > 0
          spaces.each do |thespace|
            $log.debug("ea(4): space: #{thespace.name} found")
            if thespace.name.include?("spacename-")
              $log.info("ea(5): deleting stac2 generated space: #{thespace.name}")
              total_spaces_count = total_spaces_count + 1
              thespace.delete! if delete_flag == true
            end
          end
        end
      end
    end

    rv['user:stats_summary'] = {'users_with_apps' => users_with_apps,
                                'total_app_count' => total_app_count,
                                'users_with_services' => users_with_services,
                                'total_services_count' => total_services_count,
                                'total_spaces_count' => total_spaces_count}

    $log.info "ea(rv): #{rv.pretty_inspect}"
    rv
  end


  def assignWorkloads(apps)

    # load the workload definitions from redis hash
    # the apps are static and each nabv has these as globals
    # loaded at boot.
    t = @redis.hget("cf::workloadhash", @cmd['wl'])
    if !t
      t = @redis.hget("cf::workloadhash", 'sys_basic')
    end
    @t = JSON.parse(t)

    # assign config
    @cloud = $default_cloud
    if @cmd['cloud'] && $configs[@cmd['cloud']]
      @cloud = $configs[@cmd['cloud']]
    end
    @apps = apps.clone
    assignUser
    @target = "http://#{@cloud['cc_target']}"
    @v2cache = JSON.parse(@redis.get("cf::#{@cloud['shortname']}::v2cache"))
    if @cloud['mode'] == 'v2'
      @cloudmode = :v2
      @spacename = @cloud['space']
      @orgname = @cloud['org']
      @appdomain = nil
    else
      @appdomain = @cloud['app_domain']
      @cloudmode = :v1
    end
    allocateNames 'appname', @t['appnames'] if @t['appnames']
    allocateNames 'servicename', @t['servicenames'] if @t['servicenames']
    allocateNames 'spacename', @t['spacenames'] if @t['spacenames']
  end

  # called once the object has had its
  # template assigned. populates user/password
  # in the
  def assignUser
    $log.debug("lu: cloud: #{@cloud.pretty_inspect}")

    # @cloud['users'] is an array of user objects represented
    # as {"name"=>"the-user-name", "password"=>""the-password"},

    # this function randomly selects a user from the user pool
    workers = @cloud['users']
    length = workers.length
    selected_index = rand(length)
    selected = workers[selected_index]
    log_user_activity(@cloud['shortname'], selected['name'])

    $log.debug("assignUser: #{selected.pretty_inspect}")

    @user = selected['name']
    @password = selected['password']
  end

  # called once to dynamically create names (using uuid strings)
  # for the appnames, servicenames, and spacenames section in the template
  def allocateNames(pfx, nt)
    nt.each_index do |i|
      nt[i] = "#{pfx}-#{UUIDTools::UUID.timestamp_create.to_s}" if nt[i] == 'please-compute'
    end
  end

  # execute a single workitem
  # this means first establishing context with a target, then login
  # then recursively exec the various operations (sequence, or loop)
  def execute
    if continueWorking?
      log_instance :add, @cloud['shortname']
      @cmd['n'].times do
        @cfclient = CFoundry::Client.new(@target)
        @cfclient.log = []
        #@cfclient.trace = true

        # now whip through the workload and execute the loops and sequences
        ops = @t['operations']
        executeOps ops
        if @cmd['n'] > 1
          if !continueWorking? || @fatal_abort
            log_instance :remove, @cloud['shortname']
            return
          end
        end
      end
      log_instance :remove, @cloud['shortname']
    end
  end

  # rundown a workitem and clean
  # up any dangling apps/services
  # this is done very brute force by simply deleting any application
  # or service listed in the servicenames or appnames section of the
  # workitem
  def rundown
    begin
      @cfclient.login(@user, @password)
      login_extras
      if @t['appnames']
        @t['appnames'].each do |app|
          theapp = @cfclient.app_by_name(app)
          if theapp && theapp.exists?
            if @cloudmode == :v2
              if app.include?("appname-") || app.include("caldecott")
                theapp.routes.each do |r|
                  $log.debug("rundown: deleting route #{r.host}, #{r.pretty_inspect}")
                  theapp.remove_route(r)
                  r.delete!
                end
              end
            end
            $log.info("rundown: deleting app #{app} for #{@user}")
            if app.include?("appname-") || app.include?("caldecott")
              theapp.delete!
            end
          end
        end
      end
      if @t['servicenames']
        @t['servicenames'].each do |service|
          theservice = @cfclient.service_instance_by_name(service)
          if theservice && theservice.exists?
            $log.info("rundown: deleting service #{service} for #{@user}")
            theservice.delete! if service.include? "servicename-"
          end
        end
      end
      if @cloudmode == :v2
        if @t['spacenames']
          @t['spacenames'].each do |space|
            thespace = @cfclient.space_by_name(space)
            if thespace && thespace.exists?

              # todo(markl): need to add service and app rundown, clean the space
              # as part of deletion. need to work out with alex if this should be
              # a force flag on .delete!
              $log.info("rundown: deleting space #{space} for #{@user}")
              thespace.delete! if space.include? "spacename-"
            end
          end
        end
      end


    rescue Exception => e
      # we should expect this exception to occur in certain cases. e.g., if the
      # sequence is create app and then bind-service, IF we blow up on create-app,
      # the app rundown code will fail with app not found. this is not an error,
      # just something that can happen due to an abort.
      $log.debug("** rundown failure for: #{@user} #{e.pretty_inspect}")
    end
  end

  def continueWorking?
    rv = true
    # check to see if cmax setting
    # allows us to continue
    cmax = @redis.get("cf::#{@cloud['shortname']}::cmax").to_i
    aw = @redis.scard("cf::#{@cloud['shortname']}::active_workers").to_i
    if aw > cmax
      $log.info("continueWorking?: aborting item: #{@user}, #{aw} > #{cmax}")
      rv = false
    end
    rv
  end

  def executeOps(ops)
    ops.each do |o|
      $log.debug("o: #{o.pretty_inspect}")
      case o['op']
        when 'sequence'
          executeSequence o
        when 'loop'
          executeLoop o
        else
          $log.warn("invalid op: #{0.pretty_inspect}")
      end
      return if @fatal_abort
    end
  end

  # exec a list of flat actions
  def executeSequence(s)
    $log.debug("executeSequence: #{s.pretty_inspect}")
    actions = s['actions']
    actions.each do |a|
      return if @fatal_abort

      # I need to figure out how to do this logic, BUT
      # also execute any sequence level cleanup
      #if !continueWorking?
      #  $log.debug "BAILIN"
      #  log_instance :remove, @cloud['shortname']
      ##  return
      #end

      score = 1
      # each action is a relatively simple cf command
      # e.g., apps, info, etc.
      # simple commands executed inline
      $log.info("executeSequence-start: #{a['action']}, #{@user}")
      begin
        startTime = Time.now
        action_name = a['action']
        log_action = action_name
        rv = nil

        if action_name != 'http_operation' && action_name != 'http_drain'
          $log.info("calling log_start_action: #{log_action}, #{@cloud['shortname']}")
          log_start_action(log_action, @cloud['shortname'])
        end

        $log.debug("ea: #{action_name}")
        case action_name

          when 'login'
            rv = @cfclient.login(@user, @password)
            raise "failure executing action: #{action_name}" if !@cfclient.logged_in?
            login_extras

          when 'apps'
            rv = @cfclient.apps
            $log.debug "apps: #{ap(rv)}"

          when 'user_services'
            rv = @cfclient.service_instances

          when 'system_services'
            rv = @cfclient.services

          when 'info'
            rv = @cfclient.info

          when 'pause'
            # two cases.
            # - when a['max'] is supplied, random sleep up to max seconds
            # - when a['abs'] is supplied, sleep for abs seconds
            sleeptime = 0
            if a['max']
              sleeptime = rand(a['max'])
            elsif a['abs']
              sleeptime = a['abs']
            end
            $log.debug "sleeping for #{sleeptime}"
            sleep(sleeptime)
            rv = sleeptime

          # apps
          when 'create_app'
            suspended = false
            suspended = true if a['suspended']
            appname = @t['appnames'][a['appname']]
            stacapp = @apps[a['app']]

            # create the app object
            newapp = @cfclient.app
            newapp.name = appname
            newapp.total_instances = stacapp['instances']
            newapp.memory = stacapp['memory']

            raise "failure(0.1) executing action: #{action_name}" if @appdomain == nil
            if @cloudmode == :v1
              newapp.uris = ["http://#{appname}.#{@appdomain}"]
              newapp.create!
            else
              route = @cfclient.route
              route.host = "#{appname}"
              route.domain = @appdomain
              route.space = @space_obj
              route.create!
              $log.debug("create_app(1): creating route in: #{route.space.name}: #{route.host}.#{route.domain.name}")
              newapp.production = true
              newapp.space = @space_obj
              newapp.routes = [route]
              newapp.create!
              $log.debug("create_app(2): app created in in: #{newapp.space.organization.name} #{newapp.space.name}")
            end
            raise "failure(0) executing action: #{action_name}" if !newapp.exists?

            # upload its bits
            newapp.upload(File.join($basepath, stacapp['path']))
            newapp.start! if !suspended
            raise "failure(1) executing action: #{action_name}" if newapp.started? && suspended
            raise "failure(2) executing action: #{action_name}" if newapp.stopped? && !suspended
            #raise "debug breakpoint action: #{action_name}"

          when 'start_app'
            @cfclient.app_by_name(@t['appnames'][a['appname']]).start!
            raise "failure executing action: #{action_name}" if !@cfclient.app_by_name(@t['appnames'][a['appname']]).started?

          when 'stop_app'
            @cfclient.app_by_name(@t['appnames'][a['appname']]).stop!
            raise "failure executing action: #{action_name}" if !@cfclient.app_by_name(@t['appnames'][a['appname']]).stopped?

          when 'update_app'
            suspended = false
            suspended = true if a['suspended']
            theapp = @cfclient.app_by_name(@t['appnames'][a['appname']])
            raise "failure(0) executing action: #{action_name}" if !theapp || (theapp && !theapp.exists?)

            theapp.stop!
            raise "failure(1) executing action: #{action_name}" if theapp.started?


            # note, I will make the bit upload a flag on update instead of just forcing it on?
            theapp.upload(File.join($basepath, @apps[a['app']]['path']), true)
            theapp.start! if !suspended
            raise "failure(2) executing action: #{action_name}" if theapp.started? && suspended
            raise "failure(3) executing action: #{action_name}" if theapp.stopped? && !suspended

          when 'delete_app'
            theapp = @cfclient.app_by_name(@t['appnames'][a['appname']])
            if @cloudmode == :v2
              theapp.routes.each do |r|
                $log.debug("delete_app: deleting route #{r.host}.#{r.domain.name}")
                theapp.remove_route(r)
                r.delete!
              end
            end
            theapp.delete!
            # alex somehow changed .delete!
            # it used to be that .exists? returns false on a successful delete. now .exists? is returning true
            # raise "failure(0) executing action: #{action_name}" if theapp.exists?

          when 'app_info'
            theapp = @cfclient.app_by_name(@t['appnames'][a['appname']])
            instance_count = theapp.total_instances
            raise "failure(0) executing action: #{action_name}" if !theapp.exists?

          # services
          when 'create_service'
            $log.debug("executeSequence-start: #{a['action']}, #{@user}, #{@t['servicenames'][a['servicename']]}")

            service_label = a['service']
            service_name = @t['servicenames'][a['servicename']]
            service_instance = @cfclient.service_instance
            service_instance.name = service_name

            if @cloudmode == :v1
              service_manifest = V1_SERVICE_MAP[service_label]
              raise "failure(0) executing action: #{action_name}" if !service_manifest
              service_instance.vendor = service_label
              service_instance.tier = service_manifest['tier']
              service_instance.version = service_manifest['version']
            else
              service_instance.space = @space_obj
              if a['plan']
                service_key = "#{service_label}:::#{a['plan']}"
              else
                service_key = service_label
              end
              $log.debug("create_service: l: #{service_key}, a: #{a.pretty_inspect}")
              plan_id = @v2cache['services'][service_key]
              service_instance.service_plan = @cfclient.service_plan(plan_id)
            end
            service_instance.create!
            raise "failure(1) executing action: #{action_name}" if !service_instance.exists?

          when 'bind_service'
            theapp = @cfclient.app_by_name(@t['appnames'][a['appname']])
            theapp.stop!
            raise "failure(0) executing action: #{action_name}" if !theapp.stopped?

            theservice = @cfclient.service_instance_by_name(@t['servicenames'][a['servicename']])
            raise "failure(1) executing action: #{action_name}" if !theservice.exists?

            theapp.bind(theservice)
            raise "failure(2) executing action: #{action_name}" if !theapp.binds?(theservice)

            theapp.start!
            raise "failure(3) executing action: #{action_name}" if !theapp.started?

          when 'delete_service'
            theservice = @cfclient.service_instance_by_name(@t['servicenames'][a['servicename']])
            theservice.delete!
            # same as in app.delete!, service.delete! used mean that service.exists? fails after calling service.delete!
            # now, who knows what this means, commenting out this assertion
            # raise "failure(0) executing action: #{action_name}" if theservice.exists?

          when 'create_space'
            if @cloudmode == :v2
              thespace = @cfclient.space
              thespace.name = @t['spacenames'][a['spacename']]
              thespace.organization = @cfclient.current_organization
              thespace.create!
              raise "failure(0) executing action: #{action_name}" if !thespace.exists?
            end

          when 'delete_space'
            if @cloudmode == :v2
              thespace = @cfclient.space_by_name(@t['spacenames'][a['spacename']])
              $log.debug("ds(1a): thespace, name: #{thespace.name}") if thespace
              $log.debug("ds(1b): thespace not found") if !thespace
              thespace.delete! if thespace
            end

          # http
          when 'http_operation'
            http_rv = doHttpOperation(a)

          # http_drain
          when 'http_drain'
            http_rv = doHttpDrain(a)

          when 'abort'
            raise "abort action"

          else
            # let people x-out actions with no worries
            rv = nil
        end

        endTime = Time.now
        elapsedTime = time_diff_ms(startTime, endTime)

        # todo(markl) - this shoulkd be more general? that asynch actions are supported and report defered
        if action_name == 'http_operation'
          if http_rv[:mode] == :asynchronous
            # accounting is defered
            $log.info("--executeSequence-defered: #{a['action']}, #{@user}, #{a.pretty_inspect}")
            next
            $log.warn("**executeSequence: FATALERROR, loop termination failed")
          else
            score = http_rv[:response_status]
            log_action = :http_mode
            if score >= 400
              raise "synch http failure #{score}, body #{http_rv[:response_body]}"
            end
          end
        end
        if action_name == 'http_drain'
          next
        end

        log_completion_action(log_action, @cloud['shortname'], score, elapsedTime)
        $log.debug "action: #{a['action']} ==> #{rv.pretty_inspect}"   # note, of dubious value, since rv is only set by some actions now
        $log.info("--executeSequence-success: #{a['action']}, #{@user}, #{elapsedTime}")
      rescue Exception => e
        # todo(markl) - add log stream of events
        $log.info("--executeSequence-failed: #{a['action']}, #{@user}, #{elapsedTime}, #{a.pretty_inspect}, #{e.pretty_inspect}")
        @redis.incr "cf::#{@cloud['shortname']}::actions::fail_count"
        @redis.zincrby "cf::#{@cloud['shortname']}::actions::fail_set", 1, a['action']
        $log.warn "*** action #{a['action']} failed for user #{@user}***"
        $log.warn "e: #{e.pretty_inspect}"
        $log.warn "at@ #{e.backtrace.join("\n")}"

        cflog = transform_cf_log
        # log the exception, but make sure we don't grow to more than 20 before
        # a capture cycle
        # note, cf seems to emit log records like:
        # <CLASS, DESCRIPTION,>\n
        # the code below is supposed to remove the #< and >\n
        # need to validate a 404 on synch http calls
        # note, when partial html is returned, this pattern is vulnerable so either
        # way, chop on the first > which may not always be at the end of the line
        description = e.pretty_inspect.match('^#<(.*)>.*$')[1]
        elog = {'cloud' => @cloud['shortname'],
                'action' => a['action'],
                'user' => @user,
                'e' => description,
                'tv' => Time.now.tv_sec,'host' => $app_host_ip,
                'port' => $app_host_port,
                'cflog' => cflog}

        # pump into cloud's exception_queue which gets processed and splatted into mongo
        # by the cf worker
        @redis.lpush "cf::#{@cloud['shortname']}::exception_queue", elog.to_json
        @redis.ltrim "cf::#{@cloud['shortname']}::exception_queue", 0, 100

        # always abort on exceptions
        @fatal_abort = true
      end
    end
  end

  def log_instance(add, cloud)
    @redis.sadd "cf::#{cloud}::active_workers", @active_worker_id if add == :add
    @redis.srem "cf::#{cloud}::active_workers", @active_worker_id if add == :remove
  end

  def log_user_activity(cloud, u)
    @redis.zincrby "cf::#{cloud}::active_users", 1, u
  end

  def log_action_rate(cloud, tv)
    # 1s buckets
    one_s_key = "cf::#{cloud}::rate_1s::#{tv}"

    # increment the bucket and set expires, key
    # will eventually expires Ns after the last write
    # not simple to expire ns after first create...
    @redis.incrby one_s_key, 1
    @redis.expire one_s_key, 10
  end

  def log_start_action(action, cloud)
    $log.info("log_start_action: #{action}, #{cloud}")
    tv = Time.now.tv_sec
    if action == :http_mode
      # note: js version of this code is in nabh/http-worker, this is used for asynch http
      # this version here is for synchronous
      key_prefix = "cf::#{cloud}::http"
      key_time = "#{key_prefix}::time";
      key_action_count = "#{key_prefix}::action_count";
      key_action_set = "#{key_prefix}::action_set";
      one_s_key = "cf::#{cloud}::http_rate_1s::#{tv}"

      # log success by raw count and by set count
      # increment rate bucket
      @redis.incr(key_action_count)
      @redis.zincrby(key_action_set, 1, 'http-req')
      @redis.incrby one_s_key, 1
      @redis.expire one_s_key, 10
    else
      # log success by raw count and by set count
      # increment rate bucket
      @redis.incr "cf::#{cloud}::actions::action_count"
      @redis.zincrby "cf::#{cloud}::actions::action_set", 1, action
      log_action_rate(cloud, tv)
    end
  end

  def log_completion_action(action, cloud, score, et)

    # compute the time suffix
    suffix = "_1s"
    if (et < 50.0)
      suffix = '_50'
    elsif (et >= 50.0 && et < 100.0)
      suffix = '_50_100'
    elsif (et >= 100.0 && et < 200.0)
      suffix = '_100_200'
    elsif (et >= 200.0 && et < 400.0)
      suffix = '_200_400'
    elsif (et >= 400.0 && et < 1000.0)
      suffix = '_400_1s'
    elsif (et >= 1000.0 && et < 2000.0)
      suffix = '_1s_2s'
    elsif (et >= 2000.0 && et < 3000.0)
      suffix = '_2s_3s'
    elsif (et >= 3000.0)
      suffix = '_3s'
    end

    tv = Time.now.tv_sec
    if action == :http_mode
      # note: js version of this code is in nabh/http-worker, this is used for asynch http
      # this version here is for synchronous
      key_prefix = "cf::#{cloud}::http"
      key_time = "#{key_prefix}::time";
      key_response_status_set = "#{key_prefix}::response_status_set";
      key_response_status_bucket_set = "#{key_prefix}::response_status_bucket_set";

      # grab status raw
      response_status = score.to_i;
      response_status_bucket = ((score/100.0).floor * 100).to_i;
      @redis.zincrby("#{key_time}#{suffix}", 1, 'http-req')
      @redis.zincrby(key_response_status_set, 1, response_status)
      @redis.zincrby(key_response_status_bucket_set, 1, response_status_bucket)
    else
      # log time for real ops
      if (action != 'pause')
        @redis.zincrby "cf::#{cloud}::actions::time#{suffix}", score, action
        @redis.zincrby "cf::#{cloud}::actions::time_total", et, action
      end

      action_count = @redis.zscore("cf::#{cloud}::actions::action_set", action).to_i
      action_time = @redis.zscore("cf::#{cloud}::actions::time_total", action).to_i
      action_average = action_time/action_count
      @redis.zadd "cf::#{cloud}::actions::time_average", action_average, action
      $log.debug("lca: #{action} #{et}ms, count #{action_count}, time #{action_time}, avg: #{action_average}")
    end
    # random side effect... we conditionally capture the
    # current time in redis. If the key does not exist, its
    # written. Otherwise, its left alone. This effectively
    # establishes the boot-time since last flush. Flush is as
    # simple as enumerating the cf:: keys, or at least cf::#{cloud}
    # keys and deleting them all
    ts = Time.now.tv_sec
    @redis.setnx "cf::#{cloud}::boot_time", ts
  end

  def time_diff_ms(start, finish)
    (finish - start) * 1000.0
  end

  # exec a loop which contains an iteration count, and optional
  # per iteration pause, and an operations array
  def executeLoop(l)
    $log.info("executeLoop: #{@user}, #{l['n']}, #{l.pretty_inspect}")
    n = l['n']
    ops = l['operations']
    @redis.incr "cf::#{@cloud['shortname']}::actions::loop_count"

    n.times do
      executeOps(ops)
    end

  end

  DRAIN_TIMEOUT=60
  def doHttpDrain(a)
    # this method waits for all outstanding http operations to complete
    # it does this by waiting on all of the completion queues in the @http_barrier_keys array
    # watching for the total operation count to reach the expected count.
    # if any one of the operations times out, the drain is deemed complete and the barrier array is
    # reset
    return if @http_barrier_keys.size == 0
    while true
      $log.debug "http_drain(0a): #{@http_barrier_keys.inspect}"
      $log.info "http_drain(0b): #{@http_barrier_stats.inspect}"

      # pop from queue with max 30s timeout, on timeout, declare drain complete and kill the
      # barriers
      queue, msg = @redis.blpop(*[@http_barrier_keys, DRAIN_TIMEOUT].flatten)
      if queue == nil && msg == nil
        $log.info "http_drain(0c): #{DRAIN_TIMEOUT}s timeout, declaring drain complete, #{@http_barrier_stats.inspect}"
        @http_barrier_stats = {}
        @http_barrier_keys = []
        break
      end
      count = msg.to_i
      $log.debug "http_drain(1) => #{queue}, #{count}"
      $log.debug "http_drain(2) => #{@http_barrier_stats[queue].inspect}"

      # record the count in the running sum for this queue
      @http_barrier_stats[queue][:completed] += count
      $log.debug "http_drain(3) => #{@http_barrier_stats[queue].inspect}"

      # when the completion count is >= the expected count,
      # remove the key from the barrier array and from the stats hash
      if @http_barrier_stats[queue][:completed] >= @http_barrier_stats[queue][:n]
        @http_barrier_keys.delete(queue)
        @http_barrier_stats.delete(queue)
        $log.debug "http_drain(4a) => #{@http_barrier_keys.inspect}"
        $log.debug "http_drain(4b) => #{@http_barrier_stats.inspect}"
        if @http_barrier_keys.size == 0
          $log.info "http_drain(5) => no more keys, all done"
          break
        end
      end
    end
  end

  def login_extras
    if @cloudmode == :v2
      #@org_obj = @cfclient.organization_by_name(@orgname)
      @org_obj = @cfclient.organization(@v2cache['org']['id'])
      @cfclient.current_organization = @org_obj

      @space_obj = @cfclient.space(@v2cache['space']['id'])
      #@space_obj = @cfclient.space_by_name(@spacename)
      @cfclient.current_space = @space_obj

      @appdomain = @space_obj.domains.find { |d|
        puts "#{d.name} == #{@cloud['app_domain']}?"
        d.name == @cloud['app_domain']
      }
    end
  end

  def transform_cf_log
    if @cfclient.log.is_a?(Array)
      txlog = @cfclient.log.map do |x|
        tx = {}
        tx[:method] = x[:request][:method]
        tx[:url] = x[:request][:url]
        tx[:status] = x[:response][:code]
        tx[:elapsed_time] = x[:time]
        if x[:response][:headers] && x[:response][:headers]['x-vcap-request-id']
          tx[:request_id] = x[:response][:headers]['x-vcap-request-id']
        else
          tx[:request_id] = 0
        end
        tx
      end
      txlog
    else
      []
    end
  end

  def doHttpOperation(a)
    # this method implements high volume async
    # http via nabh, IFF a['synchronous'] is set then we will do a synchronous
    # call. value of this is mostly for init calls, like the way dbrails inits
    # a database
    rv = {}
    if a['synchronous']
      log_start_action('http-req', @cloud['shortname'])
      attempts = 0
      begin
        rv[:mode] = :synchronous
        # todo(markl): this is lame, needs to do support for an args array as well...
        url = "http://#{@t['appnames'][a['appname']]}.#{@cloud['app_domain']}#{a['path']}"
        httpclient = HTTPClient.new
        response = httpclient.get url
        $log.info("doHttp-synch: #{response.status}, #{url}, #{@user}, #{a.pretty_inspect}")
        rv[:response_status] = response.status
        rv[:response_body] = response.body
        attempts = attempts + 1
        if response.status.to_i >= 400
          # on a failed call, sleep for a second before the retry
          failure = true
          sleep(1) if attempts < 4
        else
          failure = false
        end
        rv[:response_status] = response.status
      end while (failure && attempts < 4)
      #if attempts >= 4
      #  url = "http://#{@t['appnames'][a['appname']]}.#{@cloud['app_domain']}#{a['path']}"
      #  $log.info("bailing on #{url}, #{@user}, #{a.pretty_inspect}")
      #  exit
      #end
    else
      rv[:mode] = :asynchronous
      # url is a function of the appname
      host = "#{@t['appnames'][a['appname']]}.#{@cloud['app_domain']}"
      naburl = "#{$naburl}/http"
      httpclient = HTTPClient.new()
      args = {
        'host' => host,
        'path' => a['path'],
        'n' => a['n'],
        'c' => a['c'],
        'cloud' => @cloud['shortname'],
        'record_stats' => 1
      }
      args['useip'] = a['useip'] if a['useip']
      args['pipeline'] = a['pipeline'] if a['pipeline']

      response = httpclient.get naburl, args
      $log.debug "ho: #{naburl}, #{args.pretty_inspect}, --> #{response.status}"
      $log.info("doHttp-asynch: #{@user}, #{args.pretty_inspect}")
      if response.status == 200
        body = JSON.parse(response.body)
        $log.debug "ho:body: #{body.pretty_inspect}"

        # compute the completion key for this request
        # add the key to the @http_barrier_keys array
        # and also add to the @http_barrier_stats array
        # the http_drain command will wait on this data
        completion_queue = "cf::#{@cloud['shortname']}::completion_queue::#{body['uuid']}"
        stats = {
          :n => a['n'],
          :completed => 0
        }
        @http_barrier_keys << completion_queue
        @http_barrier_stats[completion_queue] = stats
        $log.debug "ho:@ #{@http_barrier_stats}"
        $log.debug "ho:@ #{@http_barrier_keys}"
      end
      rv[:response_status] = nil
    end
    rv
  end
end
