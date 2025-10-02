# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'bundler/setup'
require 'rails'
require 'minitest/autorun'
require 'set'
require 'search_engine'

# Reset registry to avoid cross-test contamination of collection mappings
begin
  SearchEngine.send(:__reset_registry_for_tests!)
rescue StandardError
  nil
end
