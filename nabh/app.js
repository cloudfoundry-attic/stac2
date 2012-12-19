// Copyright (c) 2009-2013 VMware, Inc.
var http = require('http');
var url = require('url');
var util = require('util');
require('assert');

// grab the services environment and then parse the json using
var vcap_services = JSON.parse(process.env.VCAP_SERVICES);
var vcap_app = JSON.parse(process.env.VCAP_APPLICATION);
console.log("env.VCAP_SERVICES: " + util.inspect(vcap_services));
console.log("env.VCAP_APPLICATION: " + util.inspect(vcap_app));
var instance = {};
instance["index"] = vcap_app["instance_index"];
instance["id"] = vcap_app["instance_id"];
instance["host"] = vcap_app["host"];
instance["port"] = vcap_app["port"];
console.log("app.js: instance: " + util.inspect(instance));

var redis = load_redis();
function load_redis() {
  var settings = null;
  if (vcap_services['redis-2.2']) {
    settings = vcap_services['redis-2.2'][0]
  } else {
    settings = vcap_services['redis'][0]
  }
  var ns = require('./lib/node_redis')

  var worker_client1 = ns.createClient(settings['credentials']['port'], settings['credentials']['hostname']);
  worker_client1.auth(settings['credentials']['password']);

  var worker_client2 = ns.createClient(settings['credentials']['port'], settings['credentials']['hostname']);
  worker_client2.auth(settings['credentials']['password']);


  var http_client = ns.createClient(settings['credentials']['port'], settings['credentials']['hostname']);
  http_client.auth(settings['credentials']['password']);

  return [worker_client1, worker_client2, http_client];
}

process.on('uncaughtException', function(err){
  console.log("FATALERROR: uncaughtException: " + util.inspect(err));
  console.log(err.stack);
});
console.log("ready");

var worker = require("./worker");
worker.boot(redis[0], redis[1], instance);

var server = require("./http-server");
server.boot(redis[1], instance);
