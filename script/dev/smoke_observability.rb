#!/usr/bin/env ruby

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))

require 'rails'
require 'typesense'
require 'search_engine'
require 'search_engine/client'
require 'search_engine/notifications/compact_logger'

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
  SearchEngine::Notifications::CompactLogger.subscribe(include_params: true)

  puts '[smoke] observability: single search...'
  r1 = client.search(
    collection: ENV['SMOKE_COLLECTION'] || 'products',
    params: { q: 'milk', query_by: SearchEngine.config.default_query_by,
filter_by: "category_id:=123 && brand:='Acme'" },
    url_opts: { use_cache: true, cache_ttl: 60 }
  )
  puts "[ok] single: #{r1.class}"

  puts '[smoke] observability: multi search...'
  searches = [
    {
      collection: ENV['SMOKE_COLLECTION'] || 'products',
      q: 'milk',
      query_by: SearchEngine.config.default_query_by,
      per_page: 2,
      filter_by: 'price:>10'
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
ensure
  SearchEngine::Notifications::CompactLogger.unsubscribe
end
