# Copyright (c) 2009-2013 VMware, Inc.
require 'rubygems'
require 'sinatra'

def rangerand(a,b)
  rand(b-a) + a
end

def fib(n)
  return 1 if n < 2
  return fib(n-2) + fib(n-1)
end

def time_diff_ms(start, finish)
  (finish - start) * 1000.0
end

get '/' do
  host = ENV['VCAP_APP_HOST']
  port = ENV['VCAP_APP_PORT']
  "<h1>Hello from the Cloud! via: #{host}:#{port}</h1>"
end

get '/foo' do
  '\nfoo\n'
end

get '/bar' do
  '\nbar\n'
end

# with timing
get '/fibt' do
  # chew cpu by doing a fibinocci
  # of between 31 and 38 ~500ms - 10s
  n = rangerand(31,38)
  start_time = Time.now
  t = Thread.new(n) {|fibn| fib(fibn) }
  t.join
  end_time = Time.now
  elapsed_time = time_diff_ms(start_time, end_time)
  "fib(#{n}) ==> #{elapsed_time}\n"
end

# without
get '/fib' do
  n = rangerand(31,38)
  t = Thread.new(n) {|fibn| fib(fibn) }
  "fib(#{n})\n"
end

get '/env' do
  res = ''
  ENV.each do |k, v|
    res << "#{k}: #{v}<br/>"
  end
  res
end
