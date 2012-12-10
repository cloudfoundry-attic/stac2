// nab worker
var http = require("http");
var url = require("url");
var util = require("util");
var blpop_redis = null;
var stats_redis = null;
var instance = null;

function boot(r1, r2, i) {
  instance = i;
  blpop_redis = r1;
  stats_redis = r2;
  //http.globalAgent.maxSockets = 50;
  messageWorker();
  console.log("worker has started.");
}
exports.boot = boot;

var CQ_LIFETIME = 300; // should be 300, set artificially low for debugging
// main http message worker
function messageWorker() {
  blpop_redis.blpop('http::cmd_queue', 0, function(err, data){
    //console.log(instance['index'] + ':blpop data: ' + util.inspect(data));

    // note format of data is data[0] == key, data[1] == value
    if ( !err ) {
      //console.log(data[1]);
      var cmd = JSON.parse(data[1]);
      if ( !cmd['useip']) {
        cmd._client = http.createClient(80,cmd['host']);
      }
      doWork(cmd);
    } else {
      console.log('blpop err: ' + err);
    }
    process.nextTick(messageWorker);
  });
}

function tv_msec() {
  return new Date().getTime();
}
function tv_sec() {
  return Math.round(new Date().getTime()/1000.0)
}

//
function doWork(cmd) {
  var pipeline_length = cmd.pipeline;

  if (pipeline_length > cmd.n) { pipeline_length = cmd.n;}

  var iterations = 0;
  var pipeline_iterations = 0;
  var total_requests = cmd.n;
  var total_started = 0;
  var pipeline_chunks = Math.floor(cmd.n/pipeline_length);
  if (pipeline_chunks * pipeline_length != cmd.n) {
    pipeline_chunks = pipeline_chunks+1;
  }
  process.nextTick(doRequest);

  function doRequest() {

    // queue up a pipeline full of requests
    for(var p=0; p<pipeline_length; p++){
      if ( total_started >= total_requests) {
        break;
      }
      total_started++;
      doPipelinedRequest();
    }

    function doPipelinedRequest() {

      var host = cmd['host'];
      if (cmd['useip']) {
        var ips = cmd['ip'].split(',');
        var l = ips.length;
        var ip_index = Math.floor(Math.random()*l);
        host = ips[ip_index];
        //console.log(util.format("ips: %s, index: %d, == %s", cmd['ip'], ip_index, ips[ip_index]));
      }
      // set actual host
      cmd['a_host'] = host;

      // note, setting keep-alive is not really needed as this is the default behavior
      // in node.JS > 0.4. I'm using the global agent (since agent: is not specified in options)
      // uncomment the agent and headers line specifying no keep-alive to disable keep-alive, this kills
      // the firewall in seconds
      var options = {
        host: host,
        port: 80,
        path: cmd.path,
        method: cmd.verb,
        //agent: false,
        //headers: { 'Host' : cmd['host'], 'Connection': 'close'}
        headers: { 'Host' : cmd['host'], 'Connection': 'keep-alive'}
      }
      //console.log("nabh plr: " + util.inspect(options));
      var request = http.request(options);
      var tv_msec_start = tv_msec();
      log_start_action(cmd);
      request.end();

      request.on('error', function(error) {
        console.log('exception in doWork(' + iterations + ') error:' + util.inspect(error) + ", cmd: " + util.inspect(cmd));
        var err
        perIterationAccounting(tv_msec_start, cmd, null, error.code);
        });

      request.on('socket', function(socket) {
        // socket has been assigned, this is the appropriate place
        // to snapshot the start time and request rate
        tv_msec_start = tv_msec();
        var one_s_key = "vmc::" + cmd.cloud + "::http_rate_1s::" + tv_sec();
        stats_redis.incrby(one_s_key, 1);
        stats_redis.expire(one_s_key, 10);
        });


      request.on('response', function(response) {
        response.on('data', function(chunk) {
          //console.log("ondata: " + chunk);
        });
        response.on('end', function() {
          //console.log("accounting: end");
          perIterationAccounting(tv_msec_start, cmd, response, null);
        });
        response.on('close', function(err) {
          console.log("accounting: closedetails: " + util.inspect(err));
          perIterationAccounting(tv_msec_start, cmd, response, null);
        });
      });
    }

    function log_start_action(cmd) {
      // stac2 style completion reporting
      if (cmd.record_stats && cmd.record_stats == 1) {
        // if we are supposed to record stats, then presumably
        // we are being driven by an app like stac2, the cloud
        // variable is set and the keys that we muck with are:
        // vmc::{cloud}::http::action_count
        // vmc::{cloud}::http::action_set
        // vmc::{cloud}::http::time_{50, _50_100, etc.}
        // vmc::{cloud}::http::response_status_set
        // vmc::{cloud}::http::response_status__bucket_set
        var tv = tv_sec();
        var key_prefix = "vmc::" + cmd.cloud + "::http::";
        var key_action_count = key_prefix + "action_count";
        var key_action_set = key_prefix + "action_set";

        stats_redis.incr(key_action_count);
        stats_redis.zincrby(key_action_set, 1, 'http-req');
      }
    }

    function log_completion_action(start, cmd, r, errno) {
      var tv_msec_end = tv_msec()
      var et = tv_msec_end - start;

      // stac2 style completion reporting
      if (cmd.record_stats && cmd.record_stats == 1) {
        var key_prefix = "vmc::" + cmd.cloud + "::http::";
        var key_time = "vmc::" + cmd.cloud + "::http::time";
        var key_response_status_set = key_prefix + "response_status_set";
        var key_response_status_bucket_set = key_prefix + "response_status_bucket_set";

        // grab status raw
        var response_status;
        var response_status_bucket;
        if (r) {
          response_status = r.statusCode;
          response_status_bucket = Math.floor(r.statusCode/100)*100;
        } else {
          //console.log("lca called with r==null, setting status to timeout, errno: " + errno);
          response_status = 'etimeout';
          response_status_bucket = 'etimeout';
        }
        var suffix;
        if (et < 50.0) {
          suffix = '_50';
        } else if (et >= 50.0 && et < 100.0) {
          suffix = '_50_100';
        } else if (et >= 100.0 && et < 200.0) {
          suffix = '_100_200';
        } else if (et >= 200.0 && et < 400.0) {
          suffix = '_200_400';
        } else if (et >= 400.0 && et < 1000.0) {
          suffix = '_400_1s';
        } else if (et >= 1000.0 && et < 2000.0) {
          suffix = '_1s_2s';
        } else if (et >= 2000.0 && et < 3000.0) {
          suffix = '_2s_3s';
        } else {
          suffix = "_3s";
        }
        key_time = key_time + suffix;
        stats_redis.zincrby(key_time, 1, 'http-req');
        stats_redis.zincrby(key_response_status_set, 1, response_status);
        stats_redis.zincrby(key_response_status_bucket_set, 1, response_status_bucket);

        // log the timeout if we got here to do error on connect
        var key_elog = "vmc::" + cmd.cloud + "::exception_queue";
        var elog = {};
        var ts = parseInt(new Date().getTime()/1000);
        var lr;
        var lr2;
        if (!r) {
          lr = util.format("%d, %s, %s%s", ts, errno, cmd.a_host != cmd.host ? cmd.a_host + "(" + cmd.host + ")" : cmd.host, cmd.path);
          lr2 = util.format("(%s) %s%s", errno, (cmd.a_host != cmd.host ? cmd.a_host + "(" + cmd.host + ")" : cmd.host), cmd.path);
          //console.log(lr);
          elog = {
            'cloud' : cmd.cloud,
            'action' : 'http',
            'e' : lr2,
            'user' : 'tbd',
            'tv' : parseInt(new Date().getTime()/1000),
            'host' : instance['host'],
            'port' : instance['port']
          }
          stats_redis.lpush(key_elog, JSON.stringify(elog));
        } else {
          if (response_status_bucket > 300) {
            lr = util.format("%d, %d, %s%s", ts, response_status, cmd.a_host != cmd.host ? cmd.a_host + "(" + cmd.host + ")" : cmd.host, cmd.path);
            lr2 = util.format("(%d) %s%s", response_status, (cmd.a_host != cmd.host ? cmd.a_host + "(" + cmd.host + ")" : cmd.host), cmd.path);
            //console.log(lr);
            //console.log(util.inspect(r));
            elog = {
              'cloud' : cmd.cloud,
              'action' : 'http',
              'e' : lr2,
              'user' : 'tbd',
              'tv' : parseInt(new Date().getTime()/1000),
              'host' : instance['host'],
              'port' : instance['port']
              }
            stats_redis.lpush(key_elog, JSON.stringify(elog));
          }
        }
      }
    }

    function perIterationAccounting(start, cmd, r, errno) {
      var completion_queue = "vmc::" + cmd.cloud + "::completion_queue::" + cmd.cmd_uuid;
      log_completion_action(start,cmd,r,errno);
      if (iterations < 1) {
        stats_redis.rpush(completion_queue, 0);
      }
      iterations++;

      // as soon as one request completes, send in another pipeline of requests
      // note: might want to change this to meter out the chunks of work
      // based on a pipeline worth of completions (e.g., start next pipeline of 5 after previous
      // work completes.
      pipeline_iterations++;
      if (pipeline_iterations < pipeline_chunks) {
        process.nextTick(doRequest);
      }
      if (iterations >= cmd.n) {
        if (cmd.record_stats && cmd.record_stats == 1) {
          // for this cmd chunk, we have run all
          // the requests in the cmd, finish up by
          // noting the number of requests in the
          // completion queue
          var completion_queue = "vmc::" + cmd.cloud + "::completion_queue::" + cmd.cmd_uuid;
          stats_redis.rpush(completion_queue, cmd.n);
          stats_redis.expire(completion_queue, CQ_LIFETIME);
        }
      }
    }
  }
}
