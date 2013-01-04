# Stac2

Stac2 is a load generation system for Cloud Foundry. The system is made up of several Cloud Foundry applications. The instance
count of some of the applications gates the amount of load that can be generated and depending on the size and complexity of your system,
you will have to size these to your Cloud Foundry instance using the "vmc scale --instances" command.

Installing/running Stac2 on your Cloud Foundry instance requires a small amount of configuration and setup.

* clone the stac2 repo "git clone git@github.com:cloudfoundry/stac2.git"
* create a cloud config file for your cloud into nabv/config/clouds
* nabv will not start without a properly configured cloud config file so read the [sample config](https://github.com/cloudfoundry/stac2/blob/master/nabv/config/clouds/sample-config.yml) file carefully
* create user accounts used by stac2 using "vmc register"
* note, you must use vmc version 0.4.7 or higher.
* from the stac2 repo root, where the manifest.yml file is run vmc push (note, you must have vmc 0.4.7 or higher, cfoundry 0.4.10 or higher, and manifests-vmc-plugin 0.4.17 or higher for the push to succeed)
* note: the manifest is identical between v2 and v1 systems, v2 properties are transformed into v1 properties or ignored, depending on the property.
* based on the size of your cloud and desired concurrency you will need to adjust the instance counts of nabv, nabh, and nf
    * nabv should be sized to closely match the concurrency setting in your cloud config. It should be a little over half your desired concurrency.
    for a large production cloud with a cmax of 192 set the instance count of nabv to ~100 (vmc scale nabv --instances 100).
    Note: be careful with cmax. Setting this to 32 or more requires a pretty beefy CF instance with multiple cloud controllers
    and several DEAs. If you have a very small/toy-class CF instance make sure you don't overdo it.
    * nabh should be between 16 and 32, depending on how hot of an http load you plan to run, at 32 you can easily overwhelm a small router pool with so a
    rule of thumb would be to start with 16 for most mid-sized (100+ dea clouds), 32 for 250+ dea clouds, and 4-8 for very small clouds
    * nf should be set large IFF you plan on running the high thru-put xnf_ loads. Tun run 30,000 http requests per second run between 75 and 100 instances of nf
    * stac2 is a single instance app so leave it at 1

Once stac2 is running and configured correctly, since this is the first time its been run, you need to populate it with some workloads. The static
starter set of workloads are in stac2/config/workloads. The workload selection UI has an "edit" link next to the selector so to initially
populate the default workloads click the "edit" link then the "reset workloads" link, then return the the main screen by clicking
on the "main" link. Note, any time you want to edit/reload the default workloads, just edit the file under stac2/config/workloads, re-push stac2,
and then go through the edit/reset workloads/main cycle. Fine approach for the default workloads. If you just want to change/add a workload you can do this by just uploading a new workload file
on the edit page, or delete and reload an existing workload file. The edit/reset/main path is really just for resetting things to the default state. Apologies for the
ugly edit form. What can I say. Lazy hack session one night when I just wanted to be able to let our ops guys edit/upload a workload so I built a form in an hour.

At this point, assuming your cloud config file is correct, you should be able to run some load. Select the sys_info workload in the workload selection, validate
that the cloud selector correctly selected your cloud, and then click the light gray 100% load button. You should immediately see the blue load lights
across the bottom of the screen peg to your max concurrency and you should see the counters in the main screen for the info call show activity. For a reasonable
cloud with reasonable stac2 concurrency seeing ~1,000 CC API calls per second (the yellow counter) should be easily in-reach. You should see a screen similar to this:

<p/>
![Stac2 in Action](https://github.com/cloudfoundry/stac2/raw/master/images/stac2_home.png)
<p/>

If you see no activty, then click on the reset button above the load light grid and try again. Worst case, restart nabh, then nabv,
hit the reset button, and then restart.

# Stac2 Display and Controls

Stac2 has several output only regions and only a small set of input controls.

* **timeclock** - this is a counter in the upper right that starts counting up once a scenario is started, and stops when the reset button is pressed
* **on/off controls** - in the upper left of the screen there are 6 gray'd out buttons. The first is an on/off light. When this is red, it means a scenario is running and the scenario can be
drained by clicking the red light. Next there are 5 load buttons labeled low, 25%, 50%, 75%, 100%. These determine the relative load thats going to be launched at the cloud.
Start a load by clicking one of these buttons and increase/decrease by clicking various levels. Note, since scenarios take time, decreasing the load or turning the
system off is not instantaneous. The system drains itself of work naturally and depending on the mix this could take seconds to minutes. Stac2 is inactive when the
on/off control is light gray and none of the blue lights are on in the light grid at the bottom of the screen. Make sure to let stac2 go idle before restarting components, etc.
* **load selector** - the load selector is below the on/off controls and is used to select the scenario that you intend to run. If this control is empty, follow the edit/reset/main process outlined above.
* **cloud selector** - leave this alone
* **http request counter** - this green counter on the upper right shows the amount of http traffic sent to apps created by stac2 workloads, or in the case of static loads like xnf_*, traffic to existing apps.
* **cc api calls** - this yellow counter shows the number of cloud foundry api calls executed per second
* **results table** - this large tabular region in the center of the screen shows the various api calls used by their scenarios displayed as ~equivalent vmc commands.
    * *total* - this column is the raw number of operations for this api row
    * *<50ms* - this column shows the % of api calls that executed in less than 50ms
    * *<100ms* - this column shows the % of api calls that executed in less than 100ms but more than 50ms. The column header misleads you to believe that this should include all of the <50% calls as well, but thats not the intent. Read this column as >50ms & <= 100ms.
    * *<200ms, <400ms,...>3s* - these work as you'd expect per the above definitions
    * *avg(ms)* - the average speed of the calls executed in this row
    * *err* - the % of api calls for this row that failed, note, failures are displayed as a running log under the light grid. On ccng based cloud controllers the host IP in the display is a hyperlink that takes you to a detail page showing all api calls and request id's that occurred during the mix that failed. The request id can be used for log correlation while debugging the failure.
* **results table http-request row** - this last row in the main table is similar to the previous description, but here the "api" is any http request to an app created by a scenario or a static app in the case of xnf based loads
* **results table http-status row** - this row shows the breakdown of http response status (200's, 400's, 500's) as well as those that timed out
* **email button** - if email is enabled in your cloud config, this button will serialize the results table and error log and send an email summary. Note, for non-email enabled clouds, the stac2 front-end entrypoint "/ss2?cloud=cloud-name" will produce a full JSON dump as well.
* **dirty users?** - great name... If you hit reset during an active run, or bounced your cloud under heavy activity, or restarted/repushed nabv or nabh during heavy activity, you likely left the system in a state where there are applications, services, routes, etc. that have not been properly cleared. If you see quota errors, or blue lights stuck on, thats another clue. Use this button on an idle system to ask stac2 to clean up these zombied apps and services.
Under normal operation you will not need to use this as the system self cleans anywhere it can.
* **reset** - this button flushes the redis instance at the center of the system wiping all stats, queues, error logs, etc. always use between runs on a fully quiet system. if you click on this where there is heavy activity, you will more than likely strand an application or two. If your system is seriously hosed then click reset, then vmc restart nabh; vmc restart nabv; then click reset again. This very hard reset yanks redis and restarts all workers.
* **light grid** - each light, when on, represents an active worker in the nabv app currently running an instance of the selected load. For instance if a load is designed to simulate login, push, create-service, bind-service, delete, delete-service, if one worker is currently running the load, one light will be on. If 100 lights are on, then 100 workers are simultaneously executing the load. Since stac2 is designed to be able to mimic what a typical developer is doing in front of the system, you can think if the lights as representing how many simultaneously active users the system is servicing. Active means really active though so 100 active active users can easily mean 10,000 normal users.

# Components

Stac2 consists of several, statically defined Cloud Foundry applications and services. The [manifest.yml](https://github.com/cloudfoundry/stac2/blob/master/manifest.yml) is used by the master vmc push command to create and update a stac2 cluster. The list below describes each of the static components as well as their relationship to one and other.

## stac2
The [stac2](https://github.com/cloudfoundry/stac2/tree/master/stac2) application is responsible for presenting the user interface of stac2. It's a simple, single-instance ruby/sinatra app. Multiple browser sessions may have this app open and each sessions will see the same data and control a single instance of a stac2 cluster. The bulk of the UI is written in JS which the page layout and template done in haml. When a stac2 run is in progress a lot of data is generated and the UI is supposed to feel like a realtime dashboard. As a result, there is very active JS based polling going on (10x/s) so its best have only a small number of browser sessions open at a time.

When a workload is started, stac2 communicates the desired load and settings to the system by making http requests to the nabh server.

One key entrypoint exposed by stac2 is the ability to capture all of the data rendered by the UI in it's raw JSON form (/ss2?cloud=name-of-cloud).

The stac2 app is bound to the stac2-redis redis service-instance as well as the stac2-mongo mongodb service-instance.

## nabv
The [nabv](https://github.com/cloudfoundry/stac2/tree/master/nabv) application is the main work horse of the system for executing VMC style commands (a.k.a., Cloud Controller API calls). Note: The nab* prefix came from an earlier project around auto-scaling where what I needed was an apache bench like app that I could drive programatically. I built a node.JS app called nab (network ab) and this prefix stuck as I morphed the code into two components...

The nabv app is a ruby/sinatra app that makes heavy use of the cfoundry gem/object model to make synchronous calls into cloud foundry. It's because of the synchronous nature of cfoundry that this app has so many instances. It is multi-threaded, so each instance drives more than one cfoundry client, but at this point given ruby's simplistic threading system nabv does not tax this at all...

The app receives all of its work via a set of work queue lists in the stac2-redis service-instance. The list is fed by the nabh server. Each worker does a blpop for a work item, and each work item represents scenario that the worker is supposed to run. The scenarios are described below but in a nutshell they are sets of commands/cloud controller APIs and http calls that should be made in order to simulate developer activity.

When a nabv worker is active, a blue light is on in the light grid. Since nabv is threaded, this means that a thread, in a nabv instance is actively running a workload. If anything goes wrong during a run (an exception, an API failure, etc.) the system is designed to abort the current scenario and clean up any resources (e.g., delete services, apps, routes, spaces) that may have been created by the partial scenario. Normally this is very robust, BUT IF you manually restart nabv (e.g., vmc restart nabv, or vmc push, or vmc stop/start) or do anything to manually interfere with the operation of the system, resources can be left behind. To clean these up, quiesce the app by turning stac2 off, let all of the workloads drain, and then click on the "dirty users?" button. This will iterate through the user accounts used by stac2 looking for users that are "dirty" (e.g., they have resources assigned to them that stac2 has forgotten about) and it will delete these resources.

The maximum concurrency of a run is determined by the instance count of the nabv application. If your cloud configuration has a desired maximum concurrency of 64 (e.g., cmax: 64), then make sure your nabv instance count is at least 32.

The nabv application is connected to the stac2-redis and stac2-mongo services. It is a very active writer into redis. For each operation it counts the operation, errors, increments the counters used in aggregate rate calculations, etc. When an exception occurs it spills the exception into the exception log list, it uses redis to track active workers, and as discussed before, it uses a redis list to recieve work items requesting it to run various scenarios.

## nabh
The [nabh](https://github.com/cloudfoundry/stac2/tree/master/nabh) application is a node.JS app and internally is made up of two distinct servers. One server, the http-server, is responsible for accepting work requests via http calls from either stac2, or from nabv. From stac2, the work requests are of the form: "run the sys_info scenario, across N clients, Y times". The nabh app takes this sort of request and turns this into N work items. These are pushed onto the appropriate work list in stac2-redis where they are eventually picked by by nabv. From nabv, the work requests are of the form: "run 5000 HTTP GET from N concurrent connections to the following URL". The nabh app takes this sort of requests and turns this into N http work items. These are also pushed into stac2-redis, but in this case, this work list is not processed by nabv. Instead it's processed by the other server, the http worker.

The http worker is responsible for picking up http request work items and executing the requests as quickly and efficiently as possible, performing all accounting and recording results in redis, etc. Since node.JS is an excellent platform for asynch programming this is a very efficient process. A small pool of 16-32 nabh clients can generate an enormous amount of http traffic.

The nabh app has a split personality. One half of the app acts as an API head. This app processes the API requests and converts these into workitems that are delivered to the workers via queues in redis. One pool of workers execute within the nabv app, the other pool of workers lives as a separate server running in the context of the nabh app.

The nabh app is connected to the stac2-redis service where it both reads/writes the work queues and where it does heavy recording of stats and counters related to http calls.

## nf
The [nf](https://github.com/cloudfoundry/stac2/tree/master/nf) app is not a core piece of stac2. Instead its an extra app that is used by some of the heavy http oriented workloads; specifically, those starting with **xnf_**. The app is created staticaly and because of that, heavy http scenarios can throw load at it without first launching an instance. Within the Cloud Foundry team, we use this app and the related **xnf_** workloads to stress test the firewalls, load balancers, and cloud foundry routing layer.

The nf app is a very simple node.JS http server that exposes two entrypoints: /fast-echo, an entrypoint that returns immediately with an optional response body equal to the passed "echo" argument's value, /random-data, an entrypoint that returns 1k - 512k of random data. One good scenario we use pretty extensively is the **xnf_http_fb_data** scenario. Of course this is out of date on each rev of Facebook, but when building this scenario, we did a clean load of logged in facebook.com page and observed a mix of ~130 requests that transferred ~800k of data. The **xnf_http_fb_data** scenario is an attempt to mimic this pattern by performing:
* 50 requests for 1k of data
* 50 requests for 2k of data
* 20 requests for 4k of data
* 10 requests for 32k of data
* 2 requests for 128k of data

Each run of the scenario does the above 4 times, waiting for all requests to complete before starting the next iteration. This and the **xnf_http** or **xnf_http_1k** are great ways to stress your serving infrastructure and to tune your Cloud Foundry deployment.

The **sys_http** scenario does not use the statically created version of nf. Instead each iteration of the scenario launches an instance of nf and then directs a small amount of load to the instance just launched.

## stac2-redis

The stac2-redis service instance is a Redis 2.2 service instance that is shared by all core components (stac2, nabv, nabh). All of the runtime stats, counters, and exception logs are stored in redis. In addition, the instance is used as globally visible storage for the workload data thats stored/updated in Mongodb. When this mongo based data changes, or on boot, the redis based version of the data is updated.

## stac2-mongodb

The stac2-mongo service instance is a MongoDB 2.0 service instance that us shared by the stac2 and nabv components. It's primary function is to act as the persistent storage for the workload definitions. Initially the service is empty and the edit/reset workloads/main sequence highlighted in the beginning of this document is used to initialize the workloads collection. Workloads can also be added/modified/removed using the UI on the workload edit page and these go straight into stac2-mongo (and then from there, into stac2-redis for global, high speed availability).

# Workloads

The default workloads are defined in [stac2/config/workloads](https://github.com/cloudfoundry/stac2/tree/master/stac2/config/workloads). Each workload file is a yaml file containing one or more named workloads. Using the workload management interface ("edit" link next to workload selector), workload files and all associated workloads may be deleted or added to the system. The default set of workloads can also be re-established from this page by clicking on the "reset workloads" link.

A workload is designed to mimic the activity of a single developer sitting in front of her machine ready to do a little coding. A typical vmc session might be:

    # login and look at your apps/services
    vmc login
    vmc apps
    vmc services

    # edit some code and push your app
    # curl an entrypoint or two
    vmc push foo
    curl http://foo.cloudfoundry.com/foo?arg=100
    curl http://foo.cloudfoundry.com/bar?arg=7

The workload grammar is designed to let you easily express scenarios like this and then use the stac2 framework to execute a few hundred active developers running this scenario non-stop.

In Cloud Foundry, applications and services are named objects and the names are scoped to a user account. This means that within an account, application names must be unique, and service names must be unique. With the second generation cloud controller, an additional named object, the "space" object is introduced. Application names and service names must be unqie within a space but multiple users may access and manipulate the objects. In order to reliably support this, stac2 workloads that manipulate named objects tell the system that they are going to use names and the system generates unique names for each workload in action. The workload's then refer to these named objects using indirection. E.g.:

    appnames:
      - please-compute
      - please-compute
    ...
    - action: start_app
      appname: 0

In the above fragment, the "appnames" defines an array. The value "please-compute" is a signal to the system to generate two unique appnames that will be used by an instance of the running workload. Later on, the "start_app" action (an action that roughly simulates vmc start *name-of-app*) specifies via the "appname: 0" key that it wants to use the first generated appname.

The name generation logic is applied to application (via appnames:), services (via servicenames:), and spaces (via spacenames:). A sample fragment using these looks like:

     sys_v2test_with_services:
       display: v2 playground but with service creation
       appnames:
         - please-compute

       servicenames:
         - please-compute
         - please-compute

       spacenames:
         - please-compute

       operations:
       ...

The value "please-compute" is the key to dynamic name generation. If you recall that the "nf" app is a built in app that's typically used for high http load scenarios, workloads referencing this app still use still use the appnames construct, but use static appnames. Note the full workload below that uses the existing nf app. In this workload there is a call to vmc info, and then a loop of two iterations where each iteration does 400 http GET's to the nf app's /random-data entrypoint from 4 concurrent clients. At the end of each loop iteration, the scenario waits for all outstanding http operations to complete before moving on.

    xnf_http_1k:
      display: heavy http load targeting static nf, 1k transfers
      appnames:
        - nf

      operations:
        - op: loop
          n: 1
          operations:
          - op: sequence
            actions:
              - action: info
        - op: loop
          n: 2
          operations:
            - op: sequence
              actions:
                - action: http_operation
                  appname: 0
                  path: /random-data?k=1k
                  n: 400
                  c: 4
                - action: http_drain

The other major section in a workload is the "operations" section. This is the meat of a workload containing all of the commands that end up making use of the names.
The interpretation of the workload is in [vmcworkitem.rb](https://github.com/cloudfoundry/stac2/blob/master/nabv/lib/nabv/vmcworkitem.rb), so let that be your guide
in addition to the documentation snippets that follow.

The "operations" key contains and array of "op" keys where each "op" is either a sequence of actions, or a loop of nested operations. E.g.:

    # the single element of the following operations key
    # is a sequence of actions that execute sequentially
    operations:
      - op: sequence
        actions:
          - action: login
          - action: info

    # in this operations key we have a loop with an iteration
    # count of 4. Within the loop there is a nested operations
    # key and within this we have a simple sequence. of actions
    # the first action is a variable sleep of up to 4s, the second
    # is 50 HTTP GET requests
    operations:
      - op: loop
        n: 4
        operations:
          - op: sequence
            actions:
              - action: pause
                max: 4

              # 50 requests, 1k each for 50k
              - action: http_operation
                appname: 0
                path: /random-data?k=1k
                n: 50
                c: 1

Reading through the default workloads should give you a good understanding of operations, sequences, and loops. All very simple and straightforward constructs.

The next interesting section is "actions". Within this key we have all of the Cloud Foundry vmc/api operations as well as the simple http application interactions. The schema
for each action is a function of the action. Reading the workloads and the code should give a clear understanding of the action's schema and options. When in doubt, let
[vmcworkitem.rb](https://github.com/cloudfoundry/stac2/blob/master/nabv/lib/nabv/vmcworkitem.rb) be your guide, specifically the executeSequence method.

### login

    # the "login" action executes a vmc login. The username and password is
    # dynamically assigned using credentials from the cloud config file
    # there are no arguments or options to this action
    - action: login

### apps

    # the "apps" action simulates executing the command, "vmc apps". It enumerates the apps for the current user, or
    # in v2 mode, for the current user in the selected space.
    # there are no arguments or options to this action
    - action: apps

### user_services

    # the "user_services" action simulates executing the command, "vmc services". It enumerates the services for
    # the current user, or in v2 mode, for the current user in the selected space.
    # there are no arguments or options to this action
    - action: user_services

### system_services

    # the "system_services" action simulates executing the command, "vmc info --services". It enumerates the services
    # available in the system
    # there are no arguments or options to this action
    - action: system_services

### info

    # the "info" action simulates executing the command, "vmc info", or when not authenticated
    # executing curl http://#{cc_target}/info
    # there are no arguments or options to this action
    - action: info

### pause

    # the "pause" action is used to introduce "think time" into a workload
    # it can either do a fixed sleep of N seconds, or a random sleep of up to N
    # seconds. This is indicated by the abs argument (absolute/fixed sleep),
    # or max argument for random sleep of up to N seconds. Examples of both forms
    # shown below

    # pause for 4 seconds
    - action: pause
      abs: 4

    # pause for up to 10 seconds
    - action: pause
      max: 10

### create_app

    # the "create_app" action is used to create an application. The name of the application
    # comes from the dynamically generated name from the appnames section, and this name
    # is also used to create the default route to the application. The bits, memory size,
    # framework/runtime, instance count all come from the built in apps and apps meta data,
    # all of this is documented in subsequent sections.
    # an application can be created in the started state or stopped state. The default
    # is to create the app in the started state, but if the app needs to start
    # suspended, so that for instance you can bind a required service to it, the
    # "suspended" argument can be used.

    # create an instance of the "foo" app in the started state
    # using the first appname in the list of generated appnames
    - action: create_app
      app: foo
      appname: 0


    # create an instance of the "db_rails" app in the suspended state
    # using the first appname in the list of generated appnames
    - action: create_app
      app: db_rails
      appname: 0
      suspended: true

### start_app

    # the "start_app" action is used to start an app. Normally this action is used
    # after creating an app in the stopped state and binding any services
    # required by the app. The app to be started is passed to the action using the
    # appname argument. This supplies the index into the appnames array. E.g., to
    # start the first app in the list, use "appname: 0"
    - action: start_app
      appname: 0

### stop_app

    # the "stop_app" action is used to stop an app. The app to be stopped is passed to the action using the
    # appname argument.
    - action: stop_app
      appname: 0

### update_app

    # the "update_app" action is used to simulate updating the apps bits after a minor code edit. Note, this
    # action is coded in a way that it doesn't really change an apps bits. Instead it takes advantage of
    # internal knowledge that even without changes, as long as the resources of an app are small enough
    # they will always be uploaded and re-staged. If this behavior changes, some additional code needs
    # to be added to the implementation to pro-actively dirty the app.
    # The bits for the app are specified using the app key, the same key used during app creation.
    # The app to be updated is specified using the appname argument. The app is always stopped
    # prior to the update. It is started after the update, BUT is "suspended" key is present using the
    # same form as in create_app, the updated app will be left in a stopped state.
    - action: update_app
      app: db_rails
      appname: 0

### delete_app

    # the "delete_app" action is used to delete an app and remove and delete all routes
    # that point to the app.
    - action: delete_app
      appname: 0

### app_info

    # the "app_info" action is used to retrieve the appinfo and stats for each of the app's instances. Very similar
    # to the "vmc stats" command.
    - action: app_info
      appname: 0

### create_service

    # the "create_service" action is used to create a named service instance.
    # On v1 systems, service creation is supported for redis, mysql, and postgresql services.
    # Adding the others is straightforward, but requires a small code change to include the static manifest map
    # used to drive cfoundry. On v2 systems, service creation is allows service offerings to be selected
    # by plan-name (d100, p200, etc.) and label. The core and version attributes are not supported as selectors.
    # If the plan key is supplied then it is honored on v2 systems and ignored on v1 systems. If the plan
    # key is not supplied then the d100 version of the service is created.
    # create_service requires a dynamically created service name so the workload using a service
    # must include a servicenames section similar to the way that creating an app requires an appnames section

    # create a p200 class mysql service. on v1 systems, the plan attribute is ignored and the :tier => 'free'
    # service is created (see V1_SERVICE_MAP in vmcworkitem.rb)
    - action: create_service
      service: mysql
      plan: P200
      servicename: 0

    # create a d100 class redis service
    - action: create_service
      service: redis
      servicename: 0

### bind_service

    # the "bind_service" action is used to bind an existing, named service instance to an existing, named app
    # as such, this action requires an appname and a servicename key. In all cases, before binding the app is stopped
    # and after binding the service the app is restarted. Clearly this behavior might need to be modified
    # to enable scenarios involving multiple bindings, just a few lines of code either way...
    # the following snippet shows how to bind the first dynamically generated service name to the second
    # named app
    - action: bind_service
      appname: 1
      servicename: 0

### delete_service

    # the "delete_service" action is used to delete an existing service. It is assumed that most scenarios will
    # execute this operation when the apps using the service have already been stopped or deleted.
    - action: delete_service
      servicename: 0

### create_space

    # the "create_space" action is used to create a named space. The space is created in the org programmed
    # into the cloud definition config file. This action requires a spacenames key in the workload as it uses
    # one of the names generated by that key as the name of the space
    - action: create_space
      spacename: 0

### delete_space

    # the "delete_space" action is used to delete a named space.
    - action: delete_space
      spacename: 0

### http_operation

    # the "http_operation" action is used to initiate a synchronous http GET operation, or to schedule
    # a batch of asynchronous HTTP GET operations. Note, if additional verbs are needed in the future,
    # it's just code... The purpose of this action is to simply complement the main API operations and
    # let a workload generate some http traffic to the apps. Stac2 itself is not meant to be an full service
    # http load generation/benchmarking tool so this action has some limitations, easily overcome by
    # writing some more code...
    #
    # When used in synchronous mode, a single request is made directly from the nabv component, the worker
    # executing the request stalls until it receives a response. On response status >= 400, it will retry
    # the http_operation up to four times with a sleep of 1s between each operation. This mode is mainly
    # used by stac to launch an application and then do something like initialize a database. The db_rails
    # scenario is an example of this usage. Note that synchronous mode is requested by supplying the synchronous
    # key. In addition that path is supplied, and the appname is used to determine the route to the app, with
    # the specific path appended.
    - action: http_operation
      appname: 0
      path: /db/init?n=250
      synchronous: true

    # To trigger asynchronous mode, do not supply the synchronous key. In this mode, the number of requests and
    # desired concurrency must be supplied (via n and c). For example, the following snippet shows an asynchronous
    # request for 1000 operations from 4 concurrent clients.
    - action: http_operation
      appname: 0
      path: /fast-echo
      n: 1000
      c: 4

    # depending on your configuration, you might need to run a test where you isolate Cloud Foundry from your
    # load balancing and firewall infrastructure and directly target your routers. The xnf_ workloads are perfect
    # for this use case. The "useip" key may be used to target the routers directly. When used in this mode,
    # stac2 (actually the nabh component) will act as a poor-mans load balancer and send requests to the pool
    # of ip's listed in the useip key. The Host header is then used to route to the desired application.
    # the following snippet demonstrates the use of useip to target your Cloud Foundry routers directly
    - action: http_operation
      appname: 0
      path: /fast-echo
      n: 1000
      c: 4
      useip: 172.30.40.216,172.30.40.217,172.30.40.218,172.30.40.219


### http_drain

    # the "http_drain" action is used to stall a scenario and wait for all outstanding asynchronous
    # http operations to complete or timeout.
    - action: http_drain

# Clouds

As noted in the introduction section, for your stac2 installation to work correctly, you will need to create a properly formatted and
completely specified cloud configuration file that represents your cloud. There is a fully documented [sample config](https://github.com/cloudfoundry/stac2/blob/master/nabv/config/clouds/sample-config.yml)
in nabv/config/clouds so when creating yours, model it off of this config file. For v1 clouds, it's a very simple exercise. The most
complex part is creating a pool of users that stac2 will use when running the workloads. Use vmc register for this and you will be fine.

# Apps

The applications available for use in stac2 workloads are pushed as part of the dataset of the nabv application.
The [nabv/apps](https://github.com/cloudfoundry/stac2/tree/master/nabv/apps) directory contains all of the raw code
for the apps. There are currently 5 apps:
* **db_rails** - this is a simple rails app meant to be used with mysql. It exposes an entrypoint to initialize it's
database and then once initialized, entrypoints exist to query, update, insert, and delete records. The db_rails scenario
uses this app.

* **foo** - It doesn't get too much simpler than this. A simple sinatra app that requires no services. The sys_basic*
scenarios and several others use this app to exercise app creation, etc. The variations that also generate CPU load
(sys_basic_http_cpu) use this app as well and in this case use the /fib entrypoint to launch threads to burn CPU cycles
computing Fibonacci sequences.

* **nf** - This is identical to the static node.JS based nf app, but in this case, as a source based app it may be launched
dynamically by stac2. The sys_http scenario makes use of this app.

* **springtravel** - This is a relatively large spring WAR file based Java app. Given it's size and startup complexity
it's taxing on the staging system and related caching and storage infrastructure. The app_loop_spring scenario makes
use of this app.

* **crashonboot** - This app is a variation of the ruby foo app with a syntax error that causes it to crash on startup.
Perfect app for exercising the flapping infrastructure. The app_loop_crash scenario makes use of this app.

When a workload references an application, it does it by name. The name is really the key to an application
manifest stored in [apps.yml](https://github.com/cloudfoundry/stac2/blob/master/nabv/config/apps.yml). Note the
snippet below showing that each app is defined in terms of the path to it's bits, the memory and instance
requirements, and the runtime and framework required by the app.

    apps:
      nf:
        path: apps/nf
        memory: 64
        instances: 4
        runtime: node06
        framework: node

      db_rails:
        path: apps/db_rails
        memory: 256
        instances: 1
        runtime: ruby19
        framework: rails3

      springtravel:
        path: apps/springtravel
        memory: 256
        instances: 1
        runtime: java
        framework: spring

# Administrivia

Note: this repo is managed via classic GitHub pull requests, not front ended by Gerrit.

# Trivia

Where did the name stac2 come from? The Cloud Foundry project started with a codename of b20nine. This code name was inspired by Robert Scoble's [building43](http://www.building43.com/) a.k.a., a place where all the cool stuff at Google happened. The b20nine moniker was a mythical place on the Microsoft Campus (NT was mostly built in building 27, 2 away from b20nine)... Somewhere along the way, the b20nine long form was shortened to B29, which unfortunately was the name of a devastating machine of war. In an effort to help prevent Paul Maritz from making an embarrassing joke using the B29 code name, a generic codename of "appcloud" was used briefly.

The original STAC system was developed by Peter Kukol during the "appcloud" era and in his words: "My current working acronym for the load testing harness is “STAC” which stands for the (hopefully) obvious name (“Stress-Testing of/for AppCloud”); I think that this is a bit better than ACLH, which doesn’t quite roll off the keyboard. If you can think of a better name / acronym, though, I’m certainly all ears."

In March 2012, I decided to revisit the load generation framework. Like any good software engineer, I looked Peter's original work and declared it "less than optimal" (a.k.a., a disaster) and decided that the only way to "fix it" was to do a complete and total re-write. This work was done during a 3 day non-stop coding session where I watched the sunrise twice before deciding I'm too old for this... The name Stac2 represents the second shot at building a system for "Stress-Testing of/for AppCloud". I suppose I could have just as easily named it STCF but given rampant dyslexia in the developer community I was worried about typos like STFU, etc... So I just did the boring thing and named it Stac2. Given that both Peter and I cut our teeth up north in Redmond, I'm confident that there will be a 3rd try coming. Maybe that's a good time for a new name...