// Copyright (c) 2009-2013 VMware, Inc.
// nab http server
var http = require("http");
var url = require("url");
var util = require("util");
var assert = require('assert');
var uuid = require('./lib/node_uuid/uuid')


var redis = null;

// map http urls to handlers
var routes = {
  "/http" : httpCmd,   // dispatch here for http workload generation
  "/vmc": vmcCmd,      // dispatch here for vmc workload generation
  "/stats" : stats,
  "/abort" : abort
};


// map commands to appropriate trimmed queues
var queues = {
  "http-cmd": {"name": "http::cmd_queue", "trim": 20000},
  "vmc-cmd":  {"name": "vmc::cmd_queue", "trim": 100}
}

// this is the function that bootstraps the http server
// its given its own redis client (r) and  it's vcap_instance
// in i:
// instance["index"] = vcap_app["instance_index"];
// instance["id"] = vcap_app["instance_id"];
// instance["host"] = vcap_app["host"];
// instance["port"] = vcap_app["port"];
function boot(r, i) {
  redis = r;

  // called on each http request
  // this is the dispatcher for the following stac2 generated work requests
  //  - http://nabh.your-domain.com/http -- asynch http calls, optionally status tracked
  //  - http://nabh.your-domain.com/vmc  -- vmc commands, dispatched into the vmc::{cloud}::cmd_queue
  function onRequest(request, response) {
    var u = url.parse(request.url);
    var path = u.pathname;
    //console.log("request received for: " + path);

    if (routes[path] && typeof routes[path] == 'function' ) {
      // call httpCmd or vmcCmd, depending on path
      routes[path](request, response);
    } else {
      response.writeHead(404, {"Content-Type": "text/plain"});
      response.write("404 Not Found");
      response.end();
    }
  }
  // create the server on the specified instance port wiring yourself up to the router
  server = http.createServer(onRequest).listen(i["port"]);

  // called on client side error
  server.on('clientError', function(exception){
    console.log("clientError in http server: " +util.inspect(exception));
  });

  console.log("Http Server has started.");
}
exports.boot = boot;

// todo(markl): refactor these two into a single method that is passed the cmd type

// http handlers
function httpCmd(request, response) {
  if (request.method == 'GET') {
    try {
      var cmd = createCmd(request, 'http-cmd');
      if (cmd) {
        var responseData = {};
        responseData.uuid = startGeneratingLoad(cmd);
      } else {
        throw "malformed cmd: " + util.inspect(cmd)
      }
    } catch(error) {
      response.writeHead(500, {"Content-Type": "text/plain"});
      response.write('exception in httpCmd: ' + util.inspect(error));
      response.end();
      return;
    }
    response.writeHead(200, {"Content-Type": "application/json"});
    response.write(JSON.stringify(responseData));
  } else {
    response.writeHead(400, {"Content-Type": "text/plain"});
    response.write('400 - Bad Request');
  }
  response.end();
}

// place command on the vmc queue
function vmcCmd(request, response) {
  if (request.method == 'GET') {
    try {
    var cmd = createCmd(request, 'vmc-cmd');

    var responseData = {};
    responseData.uuid = startGeneratingLoad(cmd);
    } catch (error) {
      response.writeHead(500, {"Content-Type": "text/plain"});
      response.write('exception in vmcCmd: ' + util.inspect(error));
      response.end();
      return;
    }
    response.writeHead(200, {"Content-Type": "application/json"});
    response.write(JSON.stringify(responseData));
  } else {
    response.writeHead(400, {"Content-Type": "text/plain"});
    response.write('400 - Bad Request');
  }
  response.end();
}


function stats(request, response) {
  console.log("inside stats")
  response.writeHead(200, {"Content-Type": "text/plain"});
  response.write("OK: stats");
  response.end();
}

function abort(request, response) {
  console.log("inside abort")
  response.writeHead(200, {"Content-Type": "text/plain"});
  response.write("OK: abort");
  response.end();
}


// load generation prep
var CMAX=256
var CMAX_SLOP=2
function startGeneratingLoad(cmd) {

  // break up the single cmd into a collection of
  // work items
  cmd.uuid = uuid.v4();
  cmd.state = 'queued';

  var workItems = computeWorkItems(cmd);
  var queue = queues[cmd.type].name;

  // the above establishes vmc::cmd_queue as the default
  // we assume though that ALL VMC commands target a cloud
  // so we always send to vmc::{cloud}::cmd_queue
  cmax = null;
  active_workers = null;
  wastegate = null;
  if (cmd.type == 'vmc-cmd') {
    queue = "vmc::" + cmd.cloud + "::cmd_queue"
    if (cmd.cmax) {
      cmax = "vmc::" + cmd.cloud + "::cmax"
      active_workers = "vmc::" + cmd.cloud + "::active_workers"
      wastegate = "vmc::" + cmd.cloud + "::wastegate"
    }
  } else {
    cmax = null;
    active_workers = null;
    wastegate = null;
  }

  var queueTrim = queues[cmd.type].trim;
  //console.log(util.format("cmd.type: %s, ==> queue: %s, trim: %d",cmd.type, queue, queueTrim));

  // now run the cmds
  //console.log(util.inspect(workItems));
  for (var i=0; i < workItems.length; i++) {
    var workItemAsString = JSON.stringify(workItems[i]);

    // console.log("workitem: " + workItemAsString)
    // if cmax is in effect on this work item,
    // write the cmax to redis, then look at the
    // cardinality of active_workers. IF active_worker count > cmx+slop
    // then wastegate the work item keeping the active_worker count in check
    if (cmd.type == 'vmc-cmd' && cmd.cmax > 0) {
      redis.set(cmax, cmd.cmax);

      // read cardinality from active_workers, wastegate the item as needed

      redis.scard(active_workers, function(err, data){
        //console.log("scard response");
        //console.log(util.inspect(data));

        var active = parseInt(data);
        var maxa = cmd.cmax + CMAX_SLOP
        if (active > maxa) {
          // there are more active workers than
          // cmax allows, so drop this one on the floor
          // and count it in the wastegate
          redis.incrby(wastegate, 1);
          //console.log("wastegating: " + active + ", " + maxa + ", " + workItemAsString);
        } else {
            // todo(mhl)
            // looking just at active workers is too spiky, need to also look at queue length
            // in this path look at queue length and active and if the sum is
            // > maxa then wastegate the item
            commitItem(queue, workItemAsString)
        }
      });
    } else {
      commitItem(queue, workItemAsString)
    }
  }

  function commitItem(queue, item) {

    // rpush the item
    // on complete, trim the queue
    // note, this code silently throws away any item that would
    // overflow.
    redis.rpush(queue, item, function(err, data){
      //console.log("rpush response");
      //console.log(util.inspect(data));

      // on success, ltrim the list
      if ( !err && data > queueTrim ) {
        redis.ltrim(queue, 0, (queueTrim-1), function(err, data){

          // track the overflow trims in a scored set per queue
          redis.zincrby("queue::overflow_trims", 1, queue);
          //console.log("ltrim response");
          //console.log(util.inspect(data));
        });
      } else {
        // todo(markl): need to process these as "completed" for the sake of
        // http work items so that the barriers work properly in nabv
      }
    });
  }

  return cmd.uuid;
}


// from a single cmd object, break up the
// work into one or more items. This is a function
// of the specified concurrency (cmd.c), and the
// total iteration count

function computeWorkItems(cmd) {

  // based on the concurrency property,
  // break up work into multiple cmds
  // and dispatch to the worker pool
  var c = cmd.c;
  var n = cmd.n;
  if (c>=CMAX) c = CMAX;
  if (c>=n) c = n/2;

  var chunkSize = parseInt(n/c);
  var workItems = [];
  var ci = 0;
  while ( n > 0 ) {
    var cmdChunk = clone(cmd);
    cmdChunk.original_c = cmd.c;
    cmdChunk.c = 1;
    cmdChunk.cmd_uuid = cmd.uuid;
    cmdChunk.ci = ci;
    cmdChunk.original_n = cmd.n;
    if (n >= chunkSize) {
      cmdChunk.n = chunkSize;
      n = n - chunkSize;
    } else {
      cmdChunk.n = n;
      n = 0;
    }
    workItems.push(cmdChunk);
    ci++;
  }
  assert.equal(n, 0, "oops");

  return workItems;

  // poor mans cloner...
  function clone(src) {
    if(typeof(src) != 'object' || src == null)
      return src;
    var newInstance = {};
    for(var i in src)
      newInstance[i] = clone(src[i]);
    return newInstance;
  }
}

// create a cmd object based on the supplied query string
// note, default values will be used IF the query string
// does not contain a value, or if its value is out of range
// or mis-configured
var VMC_nMax = 5000;
var VMC_cMax = CMAX;
var HTTP_nMax = 25000;
var HTTP_plMax = 20;
var HTTP_cMax = CMAX;
function createCmd(request, cmd_type) {

  // parse the url and start the cmd object
  var q = url.parse(request.url, true).query;
  var cmd = {};
  cmd.type = cmd_type;

  // build out type specific cmd for deposit on one of the queues
  if (cmd_type == 'http-cmd') {
    if (buildHttpCmd() == null) {
      return null
    }
  } else if (cmd_type == 'vmc-cmd') {
    if (buildVmcCmd() == null) {
      return null
    }
  } else {
    return null
  }
  //console.log("createCmd: " + util.inspect(cmd))
  return cmd;

  // vmc command sanitizer
  function buildVmcCmd(){
    cmd.n = 1;
    cmd.c = 1;

    // workload and cloud, both are required
    if (q.wl) {
      cmd.wl = q.wl;
    } else {
      console.log("builtVmcCmd: invalid command, missing wl: " + util.inspect(q))
      return null;
    }
    if (q.cloud) {
      cmd.cloud = q.cloud
    } else {
      console.log("builtVmcCmd: invalid command, missing cloud: " + util.inspect(q))
      return null;
    }

    if (q.cmax) {
      cmd.cmax = parseInt(q.cmax);
      if (cmd.cmax > VMC_cMax) cmd.cmax = VMC_cMax
    }

    // compute n from query string, with range and type check
    if (q.n && (n = parseInt(q.n)) && n <= VMC_nMax) {
      cmd.n = n;
    }

    // compute c from query string, with range and type check
    if (q.c && (c = parseInt(q.c)) && c <= VMC_cMax) {
      cmd.c = c;
    }
    return cmd;
  }

  // http cmd sanitizer
  function buildHttpCmd(){
    cmd.verb = 'GET';
    cmd.n = 1;
    cmd.c = 1;
    cmd.u = 'tbd';
    cmd.pipeline = 5;
    cmd.useip = false;

    // host and path are required
    if (q.host) {
      cmd.host = q.host
    } else {
      console.log("builtHttpCmd: invalid command, missing host: " + util.inspect(q))
      return null;
    }
    if (q.path) {
      cmd.path = q.path
    } else {
      console.log("builtHttpCmd: invalid command, missing path: " + util.inspect(q))
      return null;
    }

    if (q.u) {
      cmd.u = q.u;
    }

    if (q.useip) {
      cmd.ip = q.useip;
      cmd.useip = true;
    }

    // if record_stats is present, then validate cloud is present
    // and pass on, otherwise fail the request
    if (q.record_stats && q.record_stats == 1) {
      // cloud must be present in this case
      if (q.cloud) {
        cmd.record_stats = 1
        cmd.cloud = q.cloud
      } else {
        console.log("builtHttpCmd: invalid command, missing cloud in record_stats call: " + util.inspect(q))
        return null;
      }
    }

    // compute n from query string, with range and type check
    if (q.n && (n = parseInt(q.n)) && n <= HTTP_nMax) {
      cmd.n = n;
    }

    // compute c from query string, with range and type check
    if (q.c && (c = parseInt(q.c)) && c <= HTTP_cMax) {
      cmd.c = c;
    }

    // compute n from query string, with range and type check
    if (q.pipeline && (pln = parseInt(q.pipeline)) && pln <= HTTP_plMax) {
      cmd.pipeline = pln;
    }

    return cmd;
  }
}
