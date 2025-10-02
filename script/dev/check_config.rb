#!/usr/bin/env ruby
# frozen_string_literal: true

$stdout.sync = true

# Ensure the gem's lib/ is on the load path when running directly
lib_path = File.expand_path('../../lib', __dir__)
$LOAD_PATH.unshift(lib_path) unless $LOAD_PATH.include?(lib_path)

begin
  require 'rails'
  require 'search_engine'
rescue LoadError => error
  warn 'Unable to load search_engine or rails. Run with `bundle exec` from the gem root.'
  warn error.message
  exit 1
end

cfg = SearchEngine.config

begin
  cfg.validate!
rescue ArgumentError => error
  warn "Configuration invalid: #{error.message}"
  exit 2
end

redacted = cfg.to_h_redacted
puts "SearchEngine.config => #{redacted.inspect}"

exit 0
