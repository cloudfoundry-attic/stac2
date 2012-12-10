// nab http server
var http = require("http");
var url = require("url");
var util = require("util");
var assert = require('assert');

var routes = {
  "/fast-echo" : fastEcho,      // dispatch here for http workload generation
  "/random-data": randomData    // dispatch here for vmc workload generation
};


// this is the function that bootstraps the http server
// its given it's vcap_instance in i:
// instance["index"] = vcap_app["instance_index"];
// instance["id"] = vcap_app["instance_id"];
// instance["host"] = vcap_app["host"];
// instance["port"] = vcap_app["port"];
function boot(i) {

  // called on each http request
  function onRequest(request, response) {
    var u = url.parse(request.url);
    var path = u.pathname;
    //console.log("request received for: " + path);

    if (routes[path] && typeof routes[path] == 'function' ) {
      try {
        routes[path](request, response);
      } catch(error) {
        response.writeHead(500, {"Content-Type": "text/plain"});
        response.write('exception in httpCmd: ' + util.inspect(error));
        response.end();
        return;
      }
    } else {
      response.writeHead(404, {"Content-Type": "text/plain"});
      response.write("404 Not Found");
      response.end();
      console.log("nf: 404: " + path);
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

// http handlers
function fastEcho(request, response) {
  if (request.method == 'GET') {

    // note exception handler in request handler
    // returns a generic 500 so no real need for
    // additional handler
    var responseData = "OK";

    // extract query args (if any)
    var q = url.parse(request.url, true).query;
    if (q) {
      if (q.echo) {
        responseData = q.echo;
      }
    }
    response.writeHead(200, {"Content-Type": "text/plain"});
    response.write(responseData);
  } else {
    response.writeHead(400, {"Content-Type": "text/plain"});
    response.write('400 - Bad Request');
    console.log("nf: fastEcho 400: " + path);
  }
  response.end();
}

// http handlers
function makeRandom() {
  var size = 1024 * 512
  var buf = new Buffer(size);
  var c = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  var clen = c.length
  for (var i=0; i<(size); i++) { buf[i] = c.charCodeAt(Math.floor(Math.random() * clen)); }
  return buf;
}


var buf = makeRandom();
var bufferHash = {
  '1k' : buf.slice(0,1024*1),
  '2k' : buf.slice(0,1024*2),
  '4k' : buf.slice(0,1024*4),
  '8k' : buf.slice(0,1024*8),
  '16k' : buf.slice(0,1024*16),
  '32k' : buf.slice(0,1024*32),
  '64k' : buf.slice(0,1024*64),
  '128k' : buf.slice(0,1024*128),
  '256k' : buf.slice(0,1024*256),
  '512k' : buf.slice(0,1024*512)
}

function randomData(request, response) {
  if (request.method == 'GET') {

    // note exception handler in request handler
    // returns a generic 500 so no real need for
    // additional handler
    var responseData = bufferHash['1k'];

    // extract query args (if any)
    var q = url.parse(request.url, true).query;
    if (q) {
      if (q.k && bufferHash[q.k]) {
        //console.log("all set for: " + q.k);
        responseData = bufferHash[q.k];
      }
    }
    response.writeHead(200, {"Content-Type": "text/plain"});
    response.write(responseData);
  } else {
    response.writeHead(400, {"Content-Type": "text/plain"});
    response.write('400 - Bad Request');
    console.log("nf: randomData 400: " + path);
  }
  response.end();
}
