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

process.on('uncaughtException', function(err){
  console.log("FATALERROR: uncaughtException: " + util.inspect(err));
  console.log(err.stack);
});
console.log("ready");

var server = require("./http-server");
server.boot(instance);
