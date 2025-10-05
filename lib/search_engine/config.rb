# frozen_string_literal: true

require 'set'

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
    # @!attribute [rw] default_console_model
    #   @return [Class, String, nil] default model used by console helpers (SE.q/SE.rel)
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
                  :multi_search_limit,
                  :client,
                  :default_console_model

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
      # @return [Symbol] dispatcher mode: :active_job or :inline
      attr_accessor :dispatch
      # @return [String] queue name for ActiveJob enqueues
      attr_accessor :queue_name

      def initialize
        @batch_size = 2000
        @timeout_ms = nil
        @retries = { attempts: 3, base: 0.5, max: 5.0, jitter_fraction: 0.2 }
        @gzip = false
        @dispatch = active_job_available? ? :active_job : :inline
        @queue_name = 'search_index'
      end

      private

      def active_job_available?
        defined?(::ActiveJob::Base)
      end
    end

    # Lightweight nested configuration for data source adapters.
    class SourcesConfig
      # Defaults for ActiveRecord-backed source adapter.
      class ActiveRecordConfig
        # @return [Integer] default batch size for ORM batching
        attr_accessor :batch_size
        # @return [Boolean] mark relations as readonly to avoid dirty tracking
        attr_accessor :readonly
        # @return [Boolean] wrap fetching into a read-only transaction (best-effort, off by default)
        attr_accessor :use_transaction

        def initialize
          @batch_size = 2000
          @readonly = true
          @use_transaction = false
        end
      end

      # Defaults for raw SQL streaming source adapter.
      class SQLConfig
        # @return [Integer] default fetch size for server-side cursor/streaming
        attr_accessor :fetch_size
        # @return [Integer, nil] optional per-statement timeout (ms)
        attr_accessor :statement_timeout_ms
        # @return [Symbol] preferred row shape (:auto, :hash)
        attr_accessor :row_shape

        def initialize
          @fetch_size = 2000
          @statement_timeout_ms = nil
          @row_shape = :auto
        end
      end

      # Defaults for lambda-backed source adapter.
      class LambdaConfig
        # @return [Integer, nil] optional hint used for validation/metrics only
        attr_accessor :max_batch_size_hint

        def initialize
          @max_batch_size_hint = nil
        end
      end

      # @return [SearchEngine::Config::SourcesConfig::ActiveRecordConfig]
      def active_record
        @active_record ||= ActiveRecordConfig.new
      end

      # @return [SearchEngine::Config::SourcesConfig::SQLConfig]
      def sql
        @sql ||= SQLConfig.new
      end

      # @return [SearchEngine::Config::SourcesConfig::LambdaConfig]
      def lambda
        @lambda ||= LambdaConfig.new
      end
    end

    # Lightweight nested configuration for mapper.
    class MapperConfig
      # @return [Boolean] when true, unknown keys raise; when false, they are reported as warnings
      attr_accessor :strict_unknown_keys
      # @return [Hash] nested coercions config: { enabled: Boolean, rules: Hash }
      attr_accessor :coercions
      # @return [Integer] maximum number of error samples to include in reports
      attr_accessor :max_error_samples

      def initialize
        @strict_unknown_keys = false
        @coercions = { enabled: false, rules: {} }
        @max_error_samples = 5
      end
    end

    # Lightweight nested configuration for partitioning.
    class PartitioningConfig
      # @return [Proc, nil] optional resolver for default physical collection
      attr_accessor :default_into_resolver
      # @return [Integer, nil] timeout in ms for before hook
      attr_accessor :before_hook_timeout_ms
      # @return [Integer, nil] timeout in ms for after hook
      attr_accessor :after_hook_timeout_ms
      # @return [Integer] maximum error samples to include in payloads
      attr_accessor :max_error_samples

      def initialize
        @default_into_resolver = nil
        @before_hook_timeout_ms = nil
        @after_hook_timeout_ms = nil
        @max_error_samples = 5
      end
    end

    # Lightweight nested configuration for stale deletes.
    class StaleDeletesConfig
      # @return [Boolean] global kill switch
      attr_accessor :enabled
      # @return [Boolean] strict mode blocks suspicious filters
      attr_accessor :strict_mode
      # @return [Integer, nil] timeout in ms for delete requests
      attr_accessor :timeout_ms
      # @return [Boolean] enable found estimation via search
      attr_accessor :estimation_enabled

      def initialize
        @enabled = true
        @strict_mode = false
        @timeout_ms = nil
        @estimation_enabled = false
      end
    end

    # Lightweight nested configuration for observability/logging.
    class ObservabilityConfig
      # @return [Boolean] enable the compact logging subscriber automatically
      attr_accessor :enabled
      # @return [Symbol] :kv or :json
      attr_accessor :log_format
      # @return [Integer] maximum message length for error samples in logs
      attr_accessor :max_message_length
      # @return [Boolean] include short error messages in logs for batch/stale events
      attr_accessor :include_error_messages
      # @return [Boolean] also emit legacy event aliases where applicable
      attr_accessor :emit_legacy_event_aliases

      def initialize
        @enabled = true
        @log_format = :kv
        @max_message_length = 200
        @include_error_messages = false
        @emit_legacy_event_aliases = true
      end
    end

    # Lightweight nested configuration for grouping UX.
    class GroupingConfig
      # @return [Boolean] emit non-fatal warnings for ambiguous combinations
      attr_accessor :warn_on_ambiguous

      def initialize
        @warn_on_ambiguous = true
      end
    end

    # Lightweight nested configuration for selection/hydration.
    # Controls strictness of missing attributes during hydration.
    class SelectionConfig
      # @return [Boolean] when true, missing requested fields raise MissingField
      attr_accessor :strict_missing

      def initialize
        @strict_missing = false
      end
    end

    # Lightweight nested configuration for default presets resolution.
    # Controls namespacing and enablement.
    class PresetsConfig
      # @return [Boolean] when false, namespace is ignored but declared tokens remain usable
      # @see docs/presets.md
      attr_accessor :enabled
      # @return [String, nil] optional namespace prepended to preset names when enabled
      # @see docs/presets.md
      attr_accessor :namespace

      # @return [Array<Symbol>] list of request param keys that presets manage in :lock mode
      #   Any matching keys will be pruned from chain-compiled params. Defaults to
      #   %i[filter_by sort_by include_fields exclude_fields].
      # @see docs/presets.md#strategies-merge-only-lock

      def initialize
        @enabled = true
        @namespace = nil
        @locked_domains = %i[filter_by sort_by include_fields exclude_fields]
        @locked_domains_set = nil
      end

      # Normalize a Boolean-like value.
      # Accepts true/false, or common String forms ("true","false","1","0","yes","no","on","off").
      # @param value [Object]
      # @return [Boolean]
      # @see docs/presets.md#config-default-preset
      def self.normalize_enabled(value)
        return true  if value == true
        return false if value == false

        if value.is_a?(String)
          v = value.strip.downcase
          return true  if %w[1 true yes on].include?(v)
          return false if %w[0 false no off].include?(v)
        end

        value
      end

      # Normalize namespace to a non-empty String or return original for validation.
      # @param value [Object]
      # @return [String, nil, Object]
      # @see docs/presets.md#config-default-preset
      def self.normalize_namespace(value)
        return nil if value.nil?

        if value.is_a?(String)
          ns = value.strip
          return nil if ns.empty?

          return ns
        end

        value
      end

      # Assign locked domains; accepts Array/Set or a single value. Values are
      # normalized to Symbols. Internal membership checks use a frozen Set.
      # @param value [Array<#to_sym>, Set<#to_sym>, #to_sym, nil]
      # @return [void]
      # @see docs/presets.md#strategies-merge-only-lock
      def locked_domains=(value)
        list =
          case value
          when nil then []
          when Set then value.to_a
          when Array then value
          else Array(value)
          end
        syms = list.compact.map { |k| k.respond_to?(:to_sym) ? k.to_sym : k }.grep(Symbol)
        @locked_domains = syms
        @locked_domains_set = syms.to_set.freeze
      end

      # Return the locked domains as an Array of Symbols.
      # @return [Array<Symbol>]
      # @see docs/presets.md#strategies-merge-only-lock
      def locked_domains
        Array(@locked_domains).map(&:to_sym)
      end

      # Return a frozen Set of locked domains for fast membership checks.
      # @return [Set<Symbol>]
      # @see docs/presets.md#strategies-merge-only-lock
      def locked_domains_set
        @locked_domains_set ||= locked_domains.to_set.freeze
      end
    end

    # Lightweight nested configuration for curation DSL.
    # Controls validation rules and list limits.
    class CurationConfig
      # @return [Integer] maximum number of pinned IDs allowed (default: 50)
      # @see docs/curation.md
      attr_accessor :max_pins
      # @return [Integer] maximum number of hidden IDs allowed (default: 200)
      # @see docs/curation.md
      attr_accessor :max_hidden
      # @return [Regexp] allowed curated ID pattern (used for IDs and override tags)
      # @see docs/curation.md
      attr_accessor :id_regex

      def initialize
        @max_pins = 50
        @max_hidden = 200
        @id_regex = /\A[\w\-:.]+\z/
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
      @sources = SourcesConfig.new
      @mapper = MapperConfig.new
      @partitioning = PartitioningConfig.new
      @stale_deletes = StaleDeletesConfig.new
      @observability = ObservabilityConfig.new
      @grouping = GroupingConfig.new
      @selection = SelectionConfig.new
      @presets = PresetsConfig.new
      @curation = CurationConfig.new
      @default_console_model = nil
    end

    # Expose schema lifecycle configuration.
    # @return [SearchEngine::Config::SchemaConfig]
    def schema
      @schema ||= SchemaConfig.new
    end

    # Expose grouping UX configuration.
    # @return [SearchEngine::Config::GroupingConfig]
    def grouping
      @grouping ||= GroupingConfig.new
    end

    # Expose selection/hydration configuration.
    # @return [SearchEngine::Config::SelectionConfig]
    def selection
      @selection ||= SelectionConfig.new
    end

    # Expose presets configuration.
    # @return [SearchEngine::Config::PresetsConfig]
    # @see docs/presets.md
    def presets
      @presets ||= PresetsConfig.new
    end

    # Assign presets configuration from a compatible object.
    # Accepts a PresetsConfig, a Hash-like, or an object responding to :namespace and/or :enabled (e.g., OpenStruct).
    # Normalizes values on assignment.
    # @param value [Object]
    # @return [void]
    # @see docs/presets.md#config-default-preset
    def presets=(value)
      cfg = presets
      if value.is_a?(PresetsConfig)
        @presets = value
        return
      end

      source = if value.respond_to?(:to_h)
                 value.to_h
               else
                 hash = {}
                 hash[:enabled] = value.enabled if value.respond_to?(:enabled)
                 hash[:namespace] = value.namespace if value.respond_to?(:namespace)
                 hash[:locked_domains] = value.locked_domains if value.respond_to?(:locked_domains)
                 hash
               end

      if source.key?(:enabled)
        normalized = PresetsConfig.normalize_enabled(source[:enabled])
        cfg.enabled = normalized
      end

      return unless source.key?(:namespace) || source.key?(:locked_domains)

      cfg.namespace = PresetsConfig.normalize_namespace(source[:namespace]) if source.key?(:namespace)
      cfg.locked_domains = source[:locked_domains] if source.key?(:locked_domains)
    end

    # Expose curation configuration.
    # @return [SearchEngine::Config::CurationConfig]
    def curation
      @curation ||= CurationConfig.new
    end

    # Expose observability/logging configuration.
    # @return [SearchEngine::Config::ObservabilityConfig]
    def observability
      @observability ||= ObservabilityConfig.new
    end

    # Expose partitioning configuration.
    # @return [SearchEngine::Config::PartitioningConfig]
    def partitioning
      @partitioning ||= PartitioningConfig.new
    end

    # Expose stale deletes configuration.
    # @return [SearchEngine::Config::StaleDeletesConfig]
    def stale_deletes
      @stale_deletes ||= StaleDeletesConfig.new
    end

    # Expose structured logging configuration.
    # @return [OpenStruct]
    def logging
      require 'ostruct'
      @logging ||= OpenStruct.new(mode: :compact, level: :info, sample: 1.0, logger: logger)
    end

    # Expose OpenTelemetry configuration. Optional and disabled by default.
    # @return [OpenStruct]
    def opentelemetry
      require 'ostruct'
      @opentelemetry ||= OpenStruct.new(enabled: false, service_name: 'search_engine')
    end

    # Assign OpenTelemetry configuration from a compatible object.
    # Accepts an OpenStruct, a Hash-like, or an object responding to :enabled, :service_name.
    # @param value [Object]
    # @return [void]
    def opentelemetry=(value)
      require 'ostruct'
      if value.is_a?(OpenStruct)
        @opentelemetry = value
        return
      end

      source = if value.respond_to?(:to_h)
                 value.to_h
               else
                 hash = {}
                 hash[:enabled] = value.enabled if value.respond_to?(:enabled)
                 hash[:service_name] = value.service_name if value.respond_to?(:service_name)
                 hash
               end

      otel = opentelemetry
      otel.enabled = !!source[:enabled] if source.key?(:enabled) # rubocop:disable Style/DoubleNegation
      return unless source.key?(:service_name)

      otel.service_name = (source[:service_name].to_s.empty? ? 'search_engine' : source[:service_name])
    end

    # Assign curation configuration from a compatible object.
    # Accepts a CurationConfig, a Hash-like, or an object responding to :max_pins, :max_hidden, :id_regex.
    # Validates basic types on assignment.
    # @param value [Object]
    # @return [void]
    def curation=(value)
      cfg = curation
      if value.is_a?(CurationConfig)
        @curation = value
        return
      end

      source = if value.respond_to?(:to_h)
                 value.to_h
               else
                 hash = {}
                 hash[:max_pins] = value.max_pins if value.respond_to?(:max_pins)
                 hash[:max_hidden] = value.max_hidden if value.respond_to?(:max_hidden)
                 hash[:id_regex] = value.id_regex if value.respond_to?(:id_regex)
                 hash
               end

      if source.key?(:max_pins)
        pins = source[:max_pins]
        unless pins.nil? || pins.is_a?(Integer)
          raise ArgumentError, "curation.max_pins must be an Integer (got #{pins.class})"
        end

        cfg.max_pins = pins if pins
      end

      if source.key?(:max_hidden)
        hid = source[:max_hidden]
        unless hid.nil? || hid.is_a?(Integer)
          raise ArgumentError, "curation.max_hidden must be an Integer (got #{hid.class})"
        end

        cfg.max_hidden = hid if hid
      end

      return unless source.key?(:id_regex)

      rx = source[:id_regex]
      raise ArgumentError, "curation.id_regex must be a Regexp (got #{rx.class})" unless rx.is_a?(Regexp)

      cfg.id_regex = rx
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
      raise ArgumentError, errors.join(', ') unless errors.empty?

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
        default_console_model: (
          default_console_model.respond_to?(:name) ? default_console_model.name : default_console_model
        ),
        schema: schema_hash_for_to_h,
        indexer: indexer_hash_for_to_h,
        sources: sources_hash_for_to_h,
        mapper: mapper_hash_for_to_h,
        partitioning: partitioning_hash_for_to_h,
        observability: observability_hash_for_to_h,
        selection: selection_hash_for_to_h,
        presets: presets_hash_for_to_h,
        curation: curation_hash_for_to_h
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

    def schema_hash_for_to_h
      { retention: { keep_last: schema.retention.keep_last } }
    end

    def indexer_hash_for_to_h
      {
        batch_size: indexer.batch_size,
        timeout_ms: indexer.timeout_ms,
        retries: indexer.retries,
        gzip: indexer.gzip ? true : false,
        dispatch: indexer.dispatch,
        queue_name: indexer.queue_name
      }
    end

    def sources_hash_for_to_h
      {
        active_record: {
          batch_size: sources.active_record.batch_size,
          readonly: sources.active_record.readonly ? true : false,
          use_transaction: sources.active_record.use_transaction ? true : false
        },
        sql: {
          fetch_size: sources.sql.fetch_size,
          statement_timeout_ms: sources.sql.statement_timeout_ms,
          row_shape: sources.sql.row_shape
        },
        lambda: {
          max_batch_size_hint: sources.lambda.max_batch_size_hint
        }
      }
    end

    def mapper_hash_for_to_h
      {
        strict_unknown_keys: mapper.strict_unknown_keys ? true : false,
        coercions: mapper.coercions,
        max_error_samples: mapper.max_error_samples
      }
    end

    def partitioning_hash_for_to_h
      {
        before_hook_timeout_ms: partitioning.before_hook_timeout_ms,
        after_hook_timeout_ms: partitioning.after_hook_timeout_ms,
        max_error_samples: partitioning.max_error_samples
      }
    end

    def observability_hash_for_to_h
      {
        enabled: observability.enabled ? true : false,
        log_format: observability.log_format,
        max_message_length: observability.max_message_length,
        include_error_messages: observability.include_error_messages ? true : false,
        emit_legacy_event_aliases: observability.emit_legacy_event_aliases ? true : false
      }
    end

    def selection_hash_for_to_h
      {
        strict_missing: selection.strict_missing ? true : false
      }
    end

    def presets_hash_for_to_h
      {
        enabled: presets.enabled ? true : false,
        namespace: presets.namespace,
        locked_domains: presets.locked_domains
      }
    end

    def curation_hash_for_to_h
      {
        max_pins: curation.max_pins,
        max_hidden: curation.max_hidden,
        id_regex: curation.id_regex.inspect
      }
    end

    def default_strict_fields
      if defined?(::Rails)
        !::Rails.env.production?
      else
        true
      end
    end

    def default_logger
      if defined?(::Rails)
        ::Rails.logger
      else
        require 'logger'
        Logger.new($stdout)
      end
    end

    def integer_or_nil(val)
      return nil if val.nil? || (val.is_a?(String) && val.strip.empty?)

      Integer(val)
    rescue ArgumentError, TypeError
      nil
    end

    def set_if_present(attr, value, override_existing)
      return unless !value.nil? && (override_existing || instance_variable_get(:@warned_incomplete) == false)

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

    def validate_presets
      errors = []
      en = presets.enabled
      ns = presets.namespace
      ld = Array(presets.locked_domains)

      errors << 'presets.enabled must be a Boolean' unless [true, false].include?(en)

      unless ns.nil? || (ns.is_a?(String) && !ns.strip.empty?)
        errors << 'presets.namespace must be a non-empty String or nil'
      end

      unless ld.is_a?(Array) && ld.all? { |k| k.is_a?(Symbol) }
        errors << 'presets.locked_domains must be an Array of Symbols'
      end

      errors
    end
  end
end
