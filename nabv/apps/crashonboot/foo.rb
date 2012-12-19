# Copyright (c) 2009-2013 VMware, Inc.
require 'rubygems'
require 'sinatra'

# note the typo
host = XENV['VCAP_APP_HOST']

get '/' do
  port = ENV['VCAP_APP_PORT']
  "<h1>Hello from the Cloud! via: #{host}:#{port}</h1>"
end
