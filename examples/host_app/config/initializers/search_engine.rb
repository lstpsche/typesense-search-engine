# frozen_string_literal: true

require 'search_engine'

SearchEngine.configure do |c|
  c.host             = ENV.fetch('TYPESENSE_HOST', 'localhost')
  c.port             = ENV.fetch('TYPESENSE_PORT', 8108).to_i
  c.protocol         = ENV.fetch('TYPESENSE_PROTOCOL', 'http')
  c.api_key          = ENV['TYPESENSE_API_KEY']
  c.timeout_ms       = 5_000
  c.open_timeout_ms  = 1_000
  c.retries          = { attempts: 2, backoff: 0.2 }
  c.default_query_by = 'name, description'
  c.default_infix    = 'fallback'
  c.use_cache        = true
  c.cache_ttl_s      = 60
  c.logger           = Rails.logger if defined?(Rails)
end
