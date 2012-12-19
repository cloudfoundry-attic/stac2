# Copyright (c) 2009-2013 VMware, Inc.
# This file is used by Rack-based servers to start the application.

require ::File.expand_path('../config/environment',  __FILE__)
run Dbrails::Application
