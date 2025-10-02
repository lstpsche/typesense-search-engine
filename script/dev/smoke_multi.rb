#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))

require 'rails'
require 'search_engine'
require 'search_engine/base'

# Example models for smoke (dynamic, not persisted)
class SmokeProduct < SearchEngine::Base
  collection 'products'
  attribute :id, :integer
  attribute :name, :string
end

class SmokeBrand < SearchEngine::Base
  collection 'brands'
  attribute :id, :integer
  attribute :name, :string
end

SearchEngine.configure do |c|
  c.api_key   = ENV['TYPESENSE_API_KEY'] if ENV['TYPESENSE_API_KEY']
  c.host      = ENV['TYPESENSE_HOST'] if ENV['TYPESENSE_HOST']
  c.port      = (ENV['TYPESENSE_PORT'] || c.port).to_i
  c.protocol  = ENV['TYPESENSE_PROTOCOL'] if ENV['TYPESENSE_PROTOCOL']
  c.default_query_by ||= 'name'
end

begin
  puts '[smoke] multi-search via DSL...'
  result = SearchEngine.multi_search(common: { q: 'milk', query_by: SearchEngine.config.default_query_by }) do |m|
    m.add :products, SmokeProduct.all.select(:id, :name).per(2)
    m.add :brands,   SmokeBrand.all.per(1)
  end

  puts "labels=#{result.labels.inspect}"
  result.each_pair do |label, res|
    puts "#{label}: found=#{res.found} size=#{res.size}"
  end
rescue StandardError => error
  warn "[smoke] failure: #{error.class}: #{error.message}"
  exit 1
end
