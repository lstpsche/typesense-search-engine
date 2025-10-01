#!/usr/bin/env ruby

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))

require 'rails'
require 'search_engine'
require 'search_engine/client'

# Minimal model for smoke
class SmokeProduct < SearchEngine::Base
  collection 'products'
end

# Optional: subscribe to show event payloads
if defined?(ActiveSupport::Notifications)
  ActiveSupport::Notifications.subscribe('search_engine.search') do |*args|
    ev = ActiveSupport::Notifications::Event.new(*args)
    payload = ev.payload
    puts(
      [
        '[event]',
        "collection=#{payload[:collection]}",
        "status=#{payload[:status]}",
        "duration=#{ev.duration.round(1)}ms",
        "cache=#{payload.dig(:url_opts, :use_cache)}",
        "ttl=#{payload.dig(:url_opts, :cache_ttl)}",
        "q=#{payload.dig(:params, :q).inspect}"
      ].join(' ')
    )
  end
end

# Configure quick defaults for smoke
SearchEngine.configure do |c|
  c.api_key = ENV['TYPESENSE_API_KEY'] if ENV['TYPESENSE_API_KEY']
  c.host = ENV['TYPESENSE_HOST'] if ENV['TYPESENSE_HOST']
  c.port = (ENV['TYPESENSE_PORT'] || c.port).to_i
  c.protocol = ENV['TYPESENSE_PROTOCOL'] if ENV['TYPESENSE_PROTOCOL']
  c.default_query_by ||= 'name'
end

rel = SmokeProduct.all.where(active: true).per(2)

begin
  a1 = rel.to_a
  a2 = rel.ids
  c1 = rel.count
  puts("[ok] to_a=#{a1.class} ids=#{a2.size} count=#{c1}")
rescue StandardError => error
  warn("[smoke:execute] failure: #{error.class}: #{error.message}")
  if error.respond_to?(:status)
    warn("status=#{error.status} body=#{error.respond_to?(:body) ? error.body.inspect : 'n/a'}")
  end
  exit 1
end
