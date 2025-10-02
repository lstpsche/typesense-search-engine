# frozen_string_literal: true

module SearchEngine
  # Helpers for constructing URL-level client options.
  #
  # These options should not appear in request bodies. They are derived from
  # {SearchEngine.config}. This module is intentionally minimal for M0 and will
  # be used by the client implementation in future milestones.
  module ClientOptions
    # Build URL-level options from configuration.
    # @param config [SearchEngine::Config]
    # @return [Hash] keys: :use_cache, :cache_ttl
    def self.url_options_from_config(config = SearchEngine.config)
      {
        use_cache: config.use_cache ? true : false,
        cache_ttl: Integer(config.cache_ttl_s || 0)
      }
    end
  end
end
