# Copyright (c) 2009-2013 VMware, Inc.
require 'rubygems'
require 'sinatra'

configure do
  puts "Help!"
  sleep 1
  warn "No, really help me!"

  # note the typo
  host = XENV['VCAP_APP_HOST']
  exit
end


get '/' do
  port = ENV['VCAP_APP_PORT']
  "<h1>Hello from the Cloud! via: #{host}:#{port}</h1>"
end
