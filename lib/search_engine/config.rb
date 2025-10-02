# frozen_string_literal: true

module SearchEngine
  # Central configuration container for the engine.
  #
  # Holds connection details, timeouts, retry policy, default search knobs,
  # and caching switches. Mutable by design and safe to reuse across threads
  # via the module-level {SearchEngine.configure} method.
  #
  # All attributes have sensible defaults for development. Values may be
  # hydrated from ENV via {#hydrate_from_env!}. Validation is lightweight and
  # intentionally does not require secrets at boot.
  class Config
    # @!attribute [rw] api_key
    #   @return [String, nil] secret Typesense API key (redacted in logs)
    # @!attribute [rw] host
    #   @return [String] hostname of the Typesense server
    # @!attribute [rw] port
    #   @return [Integer] TCP port for the Typesense server
    # @!attribute [rw] protocol
    #   @return [String] one of "http" or "https"
    # @!attribute [rw] timeout_ms
    #   @return [Integer] request total timeout in milliseconds
    # @!attribute [rw] open_timeout_ms
    #   @return [Integer] connect/open timeout in milliseconds
    # @!attribute [rw] retries
    #   @return [Hash] retry policy with keys { attempts: Integer, backoff: Float }
    # @!attribute [rw] logger
    #   @return [#info,#warn,#error] logger to use; defaults to Rails.logger
    # @!attribute [rw] default_query_by
    #   @return [String, nil] comma-separated list of fields used to query by
    # @!attribute [rw] default_infix
    #   @return [String] Typesense infix option (e.g., "fallback")
    # @!attribute [rw] use_cache
    #   @return [Boolean] whether to allow URL-level caching
    # @!attribute [rw] cache_ttl_s
    #   @return [Integer] cache TTL in seconds (URL-level only)
    # @!attribute [rw] strict_fields
    #   @return [Boolean] when true, the Parser validates field names/types and raises
    #     friendly errors; when false, unknown fields are allowed (operators and shapes
    #     are still validated). Defaults to true in development/test.
    # @!attribute [rw] multi_search_limit
    #   @return [Integer] maximum number of searches allowed in a single multi-search call (default: 50)
    attr_accessor :api_key,
                  :host,
                  :port,
                  :protocol,
                  :timeout_ms,
                  :open_timeout_ms,
                  :retries,
                  :logger,
                  :default_query_by,
                  :default_infix,
                  :use_cache,
                  :cache_ttl_s,
                  :strict_fields,
                  :multi_search_limit

    # Lightweight nested configuration for schema lifecycle.
    class SchemaConfig
      # Retention knobs for physical collections
      class RetentionConfig
        # @return [Integer] how many previous physical collections to keep after swap (default: 0)
        attr_accessor :keep_last

        def initialize
          @keep_last = 0
        end
      end

      # @return [SearchEngine::Config::SchemaConfig::RetentionConfig]
      attr_reader :retention

      def initialize
        @retention = RetentionConfig.new
      end
    end

    # Lightweight nested configuration for indexer/import settings.
    class IndexerConfig
      # @return [Integer] default batch size when not provided explicitly
      attr_accessor :batch_size
      # @return [Integer, nil] optional override for import read timeout (ms)
      attr_accessor :timeout_ms
      # @return [Hash] retry policy: { attempts: Integer, base: Float, max: Float, jitter_fraction: Float }
      attr_accessor :retries
      # @return [Boolean] whether to gzip JSONL payloads (disabled by default)
      attr_accessor :gzip

      def initialize
        @batch_size = 2000
        @timeout_ms = nil
        @retries = { attempts: 3, base: 0.5, max: 5.0, jitter_fraction: 0.2 }
        @gzip = false
      end
    end

    # Create a new configuration with defaults, optionally hydrated from ENV.
    #
    # @param env [#[]] environment-like object (defaults to ::ENV)
    def initialize(env = ENV)
      @warned_incomplete = false
      set_defaults!
      hydrate_from_env!(env, override_existing: true)
    end

    # Populate sane defaults for development.
    # @return [void]
    def set_defaults!
      @api_key = nil
      @host = 'localhost'
      @port = 8108
      @protocol = 'http'
      @timeout_ms = 5_000
      @open_timeout_ms = 1_000
      @retries = { attempts: 2, backoff: 0.2 }
      @default_query_by = nil
      @default_infix = 'fallback'
      @use_cache = true
      @cache_ttl_s = 60
      @strict_fields = default_strict_fields
      @logger = default_logger
      @multi_search_limit = 50
      @schema = SchemaConfig.new
      @indexer = IndexerConfig.new
      nil
    end

    # Expose schema lifecycle configuration.
    # @return [SearchEngine::Config::SchemaConfig]
    def schema
      @schema ||= SchemaConfig.new
    end

    # Expose indexer/import configuration.
    # @return [SearchEngine::Config::IndexerConfig]
    def indexer
      @indexer ||= IndexerConfig.new
    end

    # Apply ENV values to any attribute, with control over overriding.
    #
    # @param env [#[]] environment-like object
    # @param override_existing [Boolean] when true, overwrite current values
    # @return [self]
    def hydrate_from_env!(env = ENV, override_existing: false)
      set_if_present(:host, env['TYPESENSE_HOST'], override_existing)
      set_if_present(:port, integer_or_nil(env['TYPESENSE_PORT']), override_existing)
      set_if_present(:protocol, env['TYPESENSE_PROTOCOL'], override_existing)
      set_if_present(:api_key, env['TYPESENSE_API_KEY'], override_existing)
      # Accept TYPESENSE_STRICT_FIELDS as 'true'/'false' when provided
      val = env['TYPESENSE_STRICT_FIELDS']
      if !val.nil? && val.is_a?(String) && !val.strip.empty?
        normalized = %w[1 true yes on].include?(val.to_s.strip.downcase)
        set_if_present(:strict_fields, normalized, override_existing)
      end
      self
    end

    # Validate obvious misconfigurations.
    #
    # @raise [ArgumentError] if a field is invalid
    # @return [true]
    def validate!
      errors = []
      errors.concat(validate_protocol)
      errors.concat(validate_host)
      errors.concat(validate_port)
      errors.concat(validate_timeouts)
      errors.concat(validate_retries)
      errors.concat(validate_cache)
      errors.concat(validate_multi_search_limit)

      raise ArgumentError, "SearchEngine::Config invalid: #{errors.join(', ')}" unless errors.empty?

      true
    end

    # Log a one-time warning for incomplete non-fatal fields.
    # @return [void]
    def warn_if_incomplete!
      return if @warned_incomplete

      missing = []
      missing << 'api_key' if string_blank?(api_key)
      missing << 'default_query_by' if string_blank?(default_query_by)

      if missing.empty?
        # no-op
      else
        (logger || default_logger).warn(
          "[search_engine] configuration incomplete: missing #{missing.join(', ')}"
        )
      end

      @warned_incomplete = true
      nil
    end

    # Hash representation of the configuration.
    # Secrets are not redacted here.
    # @return [Hash]
    def to_h
      {
        api_key: api_key,
        host: host,
        port: port,
        protocol: protocol,
        timeout_ms: timeout_ms,
        open_timeout_ms: open_timeout_ms,
        retries: retries,
        logger: !logger.nil?,
        default_query_by: default_query_by,
        default_infix: default_infix,
        use_cache: use_cache ? true : false,
        cache_ttl_s: cache_ttl_s,
        strict_fields: strict_fields ? true : false,
        multi_search_limit: multi_search_limit,
        schema: { retention: { keep_last: schema.retention.keep_last } },
        indexer: {
          batch_size: indexer.batch_size,
          timeout_ms: indexer.timeout_ms,
          retries: indexer.retries,
          gzip: indexer.gzip ? true : false
        }
      }
    end

    # Hash representation with secrets redacted.
    # @return [Hash]
    def to_h_redacted
      redacted = to_h.dup
      redacted[:api_key] = '[REDACTED]' unless string_blank?(api_key)
      redacted
    end

    private

    def default_strict_fields
      env = if defined?(Rails) && Rails.respond_to?(:env)
              Rails.env.to_s
            else
              ENV['RACK_ENV'] || ENV['RAILS_ENV'] || 'development'
            end
      %w[development test].include?(env)
    end

    def default_logger
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger
      else
        require 'logger'
        l = Logger.new($stdout)
        l.level = Logger::INFO
        l
      end
    end

    def integer_or_nil(val)
      return nil if val.nil? || (val.is_a?(String) && val.strip.empty?)

      Integer(val)
    rescue ArgumentError, TypeError
      nil
    end

    def set_if_present(attr, value, override_existing)
      return if value.nil? || (value.is_a?(String) && value.strip.empty?)

      current = public_send(attr)
      return unless override_existing || current.nil? || (current.is_a?(String) && current.strip.empty?)

      public_send("#{attr}=", value)
    end

    def string_blank?(value)
      value.nil? || (value.respond_to?(:strip) && value.strip.empty?)
    end

    def validate_protocol
      return [] if %w[http https].include?(protocol.to_s)

      ['protocol must be "http" or "https"']
    end

    def validate_host
      return [] unless host.nil? || host.to_s.strip.empty?

      ['host must be present']
    end

    def validate_port
      return [] if port.is_a?(Integer) && port.positive?

      ['port must be a positive Integer']
    end

    def validate_timeouts
      errors = []
      errors << 'timeout_ms must be a non-negative Integer' unless timeout_ms.is_a?(Integer) && !timeout_ms.negative?

      unless open_timeout_ms.is_a?(Integer) && !open_timeout_ms.negative?
        errors << 'open_timeout_ms must be a non-negative Integer'
      end

      errors
    end

    def validate_retries
      return ['retries must be a Hash with keys :attempts and :backoff'] unless retries_valid_shape?

      errors = []
      attempts = retries[:attempts]
      backoff = retries[:backoff]

      unless attempts.is_a?(Integer) && !attempts.negative?
        errors << 'retries[:attempts] must be a non-negative Integer'
      end
      errors << 'retries[:backoff] must be a non-negative Float' unless backoff.is_a?(Numeric) && !backoff.negative?

      errors
    end

    def retries_valid_shape?
      retries.is_a?(Hash) && retries.key?(:attempts) && retries.key?(:backoff)
    end

    def validate_cache
      return [] if cache_ttl_s.is_a?(Integer) && !cache_ttl_s.negative?

      ['cache_ttl_s must be a non-negative Integer']
    end

    def validate_multi_search_limit
      return [] if multi_search_limit.is_a?(Integer) && !multi_search_limit.negative?

      ['multi_search_limit must be a non-negative Integer']
    end
  end
end
