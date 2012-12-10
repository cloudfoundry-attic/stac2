class Workload
  attr_reader :workloads
  attr_reader :workload_files

  # initialize mailer settings
  def initialize
    # bind to store and load processed workloads
    #@address = config['address']
    #@port = config['port']
    #@domain = config['domain']
    #@user_name = config['user_name']
    #@password = config['password']
    #@from = config['from']
    #@to = config['to']
    #@default = config['default']
    @workloads = {}
    @workload_files = {}
  end

  def select
    @workloads = {}
    @workload_files = {}

    # enumerate the workloads
    $log.info "select(0)"
    workloads = $mongodb.collection("workloads")
    workloads.find.each do |wldoc|
      $log.info("select(1): wldoc => #{wldoc.pretty_inspect}")
      @workloads[wldoc['__key__']] = wldoc
    end
    workload_files = $mongodb.collection("workload_files")
    workload_files.find.each do |wfdoc|
      $log.info("select(2): wfdoc => #{wfdoc.pretty_inspect}")
      @workload_files[wfdoc['file']] = wfdoc['keys']
    end
    $log.info("select(2): #{@workload_files.pretty_inspect}")
  end

  def reload_from_static_path
    @workloads = {}
    @workload_files = {}
    # enumerate the workloads
    $log.info "rlfsp(0) #{$config_path}/workloads/*.yml"
    Dir.glob("#{$config_path}/workloads/*.yml") do |fn|
      fb = File.basename(fn)
      $log.info "rlfsp(1): #{fb}"
      wl = YAML.load(File.open(fn))
      # fn should no longer be used, fb is the key
      fn = nil
      $log.debug "rlfsp(1a): #{wl.pretty_inspect}"
      @workload_files[fb] = {:file => fb, :keys => []}
      $log.debug "rlfsp(1b): #{wl['workloads'].pretty_inspect}"
      wl['workloads'].each do |k,v|
        $log.info "rlfsp(1c): |k=#{k}"
        raise "key: #{k} already exists in @workloads: #{@workloads.pretty_inspect}" if @workloads[k]
        raise "key: #{k} already exists in @workload_files: #{@workload_files.pretty_inspect}" if @workload_files[fb].include? k
        v[:__key__] = k
        v[:__file__] = fb
        @workloads[k] = v if !v['disabled']
        @workload_files[fb][:keys] << k if !v['disabled']
        $log.info("rlfsp(2): loading @workloads[#{k}]")
        $log.info("rlfsp(3): loading @workload_files[#{fb}]")
      end
    end

    # save the lists into mongo
    workloads = $mongodb.collection("workloads")
    workloads.drop
    workloads = $mongodb.collection("workloads")
    @workloads.each do |k,v|
      id = workloads.insert(v)
    end
    workload_files = $mongodb.collection("workload_files")
    workload_files.drop
    workload_files = $mongodb.collection("workload_files")
    @workload_files.each do |fb,v|
      id = workload_files.insert(v)
    end
    select
  end


  def delete(wl_key)

    # delete from workloads and workload_files
    $log.info "delete(0): #{wl_key.pretty_inspect}"

    workloads = $mongodb.collection("workloads")
    g = {}
    g['__file__'] = "#{wl_key}"
    $log.info("delete(1): workloads.remove(#{g.pretty_inspect})")
    x = workloads.remove(g)
    $log.info("delete(2): #{x.pretty_inspect}")

    workload_files = $mongodb.collection("workload_files")
    g = {}
    g['file'] = "#{wl_key}"
    $log.info("delete(3): workloads_files.remove(#{g.pretty_inspect})")
    x = workload_files.remove(g)
    $log.info("delete(4): #{x.pretty_inspect}")
    select
  end

  def upload(key, document)

    workloads = {}
    workload_files = {}
    # enumerate the workloads
    fb = key
    wl = document

    workload_files[fb] = {:file => fb, :keys => []}
    wl['workloads'].each do |k,v|
      $log.info "ul(1c): |k=#{k}|"
      v[:__key__] = k
      v[:__file__] = fb
      workloads[k] = v if !v['disabled']
      workload_files[fb][:keys] << k if !v['disabled']
      $log.info("wul(2): loading workloads[#{k}]")
      $log.info("wul(3): loading workload_files[#{fb}]")
    end

    # now update the workloads and workload_files collections
    # save the lists into mongo
    wl_collection = $mongodb.collection("workloads")
    workloads.each do |k,v|
      id = wl_collection.insert(v)
    end

    wf_collection = $mongodb.collection("workload_files")
    workload_files.each do |fb,v|
      id = wf_collection.insert(v)
    end
    select

  end
end
