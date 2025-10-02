#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))

require 'rails'
require 'typesense'
require 'search_engine'
require 'search_engine/client'

# Configure from ENV quickly for smoke testing
SearchEngine.configure do |c|
  c.api_key = ENV['TYPESENSE_API_KEY'] if ENV['TYPESENSE_API_KEY']
  c.host = ENV['TYPESENSE_HOST'] if ENV['TYPESENSE_HOST']
  c.port = (ENV['TYPESENSE_PORT'] || c.port).to_i
  c.protocol = ENV['TYPESENSE_PROTOCOL'] if ENV['TYPESENSE_PROTOCOL']
  c.default_query_by ||= 'name'
end

client = SearchEngine::Client.new

begin
  puts '[smoke] single search...'
  r1 = client.search(
    collection: ENV['SMOKE_COLLECTION'] || 'products',
    params: { q: 'milk', query_by: SearchEngine.config.default_query_by },
    url_opts: { use_cache: true }
  )
  puts "[ok] single: #{r1.class}"

  puts '[smoke] multi search...'
  searches = [
    {
      collection: ENV['SMOKE_COLLECTION'] || 'products',
      q: 'milk',
      query_by: SearchEngine.config.default_query_by,
      per_page: 2
    }
  ]
  r2 = client.multi_search(searches: searches, url_opts: { use_cache: true, cache_ttl: 30 })
  puts "[ok] multi: #{r2.class}"
rescue StandardError => error
  warn "[smoke] failure: #{error.class}: #{error.message}"
  if error.respond_to?(:status)
    warn "status=#{error.status} body=#{error.respond_to?(:body) ? error.body.inspect : 'n/a'}"
  end
  exit 1
end
