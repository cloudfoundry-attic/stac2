# Copyright (c) 2009-2013 VMware, Inc.
require 'vmc'

class VmcWorker
  class << self
    attr_reader :events
    $bucket_list = []

    def run(queues, apps, redis, redis2, workerid)
      STDOUT.sync = true

      #@haml_engine_html = Haml::Engine.new(File.read(email_template))
      #@haml_engine_plain = Haml::Engine.new(File.read(plain_template))
      #@mailer = MailStats.new(config)
      #puts @mailer.inspect

      @redis = redis
      @redis2 = redis2

      # note we use global instead, so that its no work to track
      # workload changes
      #init_buckets(redis)
      #puts $bucket_list.inspect

      while true
        $log.debug "blpop(#{queues.pretty_inspect}, 0)"
        queue, msg = @redis.blpop(*[queues, 0].flatten)
        $log.debug "blpop => #{queue}, #{msg.inspect}"
        # partial recover from a user/caldecott initiated flushall
        naburl = @redis.get("vmc::naburl")
        $log.debug("naburl: #{naburl}")
        if !naburl
          $log.warn("resetting base settings due to flushall")
          reconfig
        end

        workitem = VmcWorkItem.new(JSON.parse(msg), @redis2, apps, workerid)
        $log.debug "workitem: #{workitem.inspect}"
        workitem.execute
        workitem.rundown
      end
    end
  end
end
