# frozen_string_literal: true

require 'search_engine'
require 'search_engine/client_options'
require 'search_engine/errors'
require 'search_engine/observability'

module SearchEngine
  # Thin wrapper on top of the official `typesense` gem.
  #
  # Provides single-search and federated multi-search while enforcing that cache
  # knobs live in URL/common-params and not in per-search request bodies.
  class Client
    # @param config [SearchEngine::Config]
    # @param typesense_client [Object, nil] optional injected Typesense::Client (for tests)
    def initialize(config: SearchEngine.config, typesense_client: nil)
      @config = config
      @typesense = typesense_client
    end

    # Execute a single search against a collection.
    #
    # @param collection [String] collection name
    # @param params [Hash] Typesense search parameters (q, query_by, etc.)
    # @param url_opts [Hash] URL/common knobs (use_cache, cache_ttl)
    # @return [SearchEngine::Result] Wrapped response with hydrated hits
    # @raise [SearchEngine::Errors::InvalidParams, SearchEngine::Errors::*]
    def search(collection:, params:, url_opts: {})
      params_obj = SearchEngine::CompiledParams.from(params)
      validate_single!(collection, params_obj.to_h)

      cache_params = derive_cache_opts(url_opts)
      ts = typesense

      start = current_monotonic_ms
      payload = sanitize_body_params(params_obj.to_h)
      path = "/collections/#{collection}/documents/search"

      # Observability event payload (pre-built; redacted)
      if defined?(ActiveSupport::Notifications)
        se_payload = build_search_event_payload(
          collection: collection,
          params: params_obj.to_h,
          cache_params: cache_params
        )

        result = nil
        SearchEngine::Instrumentation.instrument('search_engine.search', se_payload) do |ctx|
          ctx[:params_preview] = SearchEngine::Instrumentation.redact(params_obj.to_h)
          result = with_exception_mapping(:post, path, cache_params, start) do
            ts.collections[collection].documents.search(payload, common_params: cache_params)
          end
          ctx[:status] = :ok
        rescue Errors::Api => error
          ctx[:status] = error.status
          ctx[:error_class] = error.class.name
          raise
        rescue Errors::Error => error
          ctx[:status] = :error
          ctx[:error_class] = error.class.name
          raise
        end
      else
        result = with_exception_mapping(:post, path, cache_params, start) do
          ts.collections[collection].documents.search(payload, common_params: cache_params)
        end
      end

      duration = current_monotonic_ms - start
      instrument(:post, path, duration, cache_params)
      log_success(:post, path, start, cache_params)
      # Wrap raw response into a Result with safe registry lookup for klass
      klass = begin
        SearchEngine.collection_for(collection)
      rescue ArgumentError
        nil
      end
      SearchEngine::Result.new(result, klass: klass)
    end

    # Resolve a logical collection name that might be an alias to the physical collection name.
    #
    # @param logical_name [String]
    # @return [String, nil] physical collection name when alias exists; nil when alias not found
    # @raise [SearchEngine::Errors::*] on network or API errors other than 404
    def resolve_alias(logical_name)
      name = logical_name.to_s
      ts = typesense
      start = current_monotonic_ms
      path = "/aliases/#{name}"

      result = with_exception_mapping(:get, path, {}, start) do
        ts.aliases[name].retrieve
      end

      (result && (result['collection_name'] || result[:collection_name])).to_s
    rescue Errors::Api => error
      return nil if error.status.to_i == 404

      raise
    ensure
      instrument(:get, path, current_monotonic_ms - start, {}) if defined?(start)
    end

    # Retrieve the live schema for a physical collection name.
    #
    # @param collection_name [String]
    # @return [Hash, nil] schema hash when found; nil when collection not found (404)
    # @raise [SearchEngine::Errors::*] on other network or API errors
    def retrieve_collection_schema(collection_name)
      name = collection_name.to_s
      ts = typesense
      start = current_monotonic_ms
      path = "/collections/#{name}"

      result = with_exception_mapping(:get, path, {}, start) do
        ts.collections[name].retrieve
      end

      symbolize_keys_deep(result)
    rescue Errors::Api => error
      return nil if error.status.to_i == 404

      raise
    ensure
      instrument(:get, path, current_monotonic_ms - start, {}) if defined?(start)
    end

    # Upsert an alias to point to the provided physical collection (atomic server-side swap).
    # @param alias_name [String]
    # @param physical_name [String]
    # @return [Hash]
    def upsert_alias(alias_name, physical_name)
      a = alias_name.to_s
      p = physical_name.to_s
      ts = typesense
      start = current_monotonic_ms
      path = "/aliases/#{a}"

      result = with_exception_mapping(:put, path, {}, start) do
        ts.aliases[a].upsert(collection_name: p)
      end

      symbolize_keys_deep(result)
    ensure
      instrument(:put, path, current_monotonic_ms - start, {}) if defined?(start)
    end

    # Create a new physical collection with the given schema.
    # @param schema [Hash] Typesense schema body
    # @return [Hash] created collection schema
    def create_collection(schema)
      ts = typesense
      start = current_monotonic_ms
      body = schema.dup
      path = '/collections'

      result = with_exception_mapping(:post, path, {}, start) do
        ts.collections.create(body)
      end

      symbolize_keys_deep(result)
    ensure
      instrument(:post, path, current_monotonic_ms - start, {}) if defined?(start)
    end

    # Delete a physical collection by name.
    # @param name [String]
    # @return [Hash] Typesense delete response
    def delete_collection(name)
      n = name.to_s
      ts = typesense
      start = current_monotonic_ms
      path = "/collections/#{n}"

      result = with_exception_mapping(:delete, path, {}, start) do
        ts.collections[n].delete
      end

      symbolize_keys_deep(result)
    rescue Errors::Api => error
      # If already gone, treat as success for idempotency
      return { status: 404 } if error.status.to_i == 404

      raise
    ensure
      instrument(:delete, path, current_monotonic_ms - start, {}) if defined?(start)
    end

    # List all collections.
    # @return [Array<Hash>] list of collection metadata
    def list_collections
      ts = typesense
      start = current_monotonic_ms
      path = '/collections'

      result = with_exception_mapping(:get, path, {}, start) do
        ts.collections.retrieve
      end

      symbolize_keys_deep(result)
    ensure
      instrument(:get, path, current_monotonic_ms - start, {}) if defined?(start)
    end

    # Perform a server health check.
    # @return [Hash] Typesense health response (symbolized where applicable)
    def health
      ts = typesense
      start = current_monotonic_ms
      path = '/health'

      result = with_exception_mapping(:get, path, {}, start) do
        ts.health.retrieve
      end

      symbolize_keys_deep(result)
    ensure
      instrument(:get, path, current_monotonic_ms - start, {}) if defined?(start)
    end

    # --- Admin: Synonyms ----------------------------------------------------
    # NOTE: We rely on the official client's endpoints; names are mapped here.

    # @param collection [String]
    # @param id [String]
    # @param terms [Array<String>]
    # @return [Hash]
    def synonyms_upsert(collection:, id:, terms:)
      c = collection.to_s
      s = id.to_s
      list = Array(terms)
      ts = typesense
      start = current_monotonic_ms
      path = "/collections/#{c}/synonyms/#{s}"

      result = with_exception_mapping(:put, path, {}, start) do
        ts.collections[c].synonyms[s].upsert({ synonyms: list })
      end
      symbolize_keys_deep(result)
    ensure
      instrument(:put, path, current_monotonic_ms - start, {}) if defined?(start)
    end

    # @return [Array<Hash>]
    def synonyms_list(collection:)
      c = collection.to_s
      ts = typesense
      start = current_monotonic_ms
      path = "/collections/#{c}/synonyms"
      result = with_exception_mapping(:get, path, {}, start) do
        ts.collections[c].synonyms.retrieve
      end
      symbolize_keys_deep(result)
    ensure
      instrument(:get, path, current_monotonic_ms - start, {}) if defined?(start)
    end

    # @return [Hash, nil]
    def synonyms_get(collection:, id:)
      c = collection.to_s
      s = id.to_s
      ts = typesense
      start = current_monotonic_ms
      path = "/collections/#{c}/synonyms/#{s}"
      result = with_exception_mapping(:get, path, {}, start) do
        ts.collections[c].synonyms[s].retrieve
      end
      symbolize_keys_deep(result)
    rescue Errors::Api => error
      return nil if error.status.to_i == 404

      raise
    ensure
      instrument(:get, path, current_monotonic_ms - start, {}) if defined?(start)
    end

    # @return [Hash]
    def synonyms_delete(collection:, id:)
      c = collection.to_s
      s = id.to_s
      ts = typesense
      start = current_monotonic_ms
      path = "/collections/#{c}/synonyms/#{s}"
      result = with_exception_mapping(:delete, path, {}, start) do
        ts.collections[c].synonyms[s].delete
      end
      symbolize_keys_deep(result)
    ensure
      instrument(:delete, path, current_monotonic_ms - start, {}) if defined?(start)
    end

    # --- Admin: Stopwords ---------------------------------------------------

    # @param collection [String]
    # @param id [String]
    # @param terms [Array<String>]
    # @return [Hash]
    def stopwords_upsert(collection:, id:, terms:)
      c = collection.to_s
      s = id.to_s
      list = Array(terms)
      ts = typesense
      start = current_monotonic_ms
      path = "/collections/#{c}/stopwords/#{s}"

      result = with_exception_mapping(:put, path, {}, start) do
        ts.collections[c].stopwords[s].upsert({ stopwords: list })
      end
      symbolize_keys_deep(result)
    ensure
      instrument(:put, path, current_monotonic_ms - start, {}) if defined?(start)
    end

    # @return [Array<Hash>]
    def stopwords_list(collection:)
      c = collection.to_s
      ts = typesense
      start = current_monotonic_ms
      path = "/collections/#{c}/stopwords"
      result = with_exception_mapping(:get, path, {}, start) do
        ts.collections[c].stopwords.retrieve
      end
      symbolize_keys_deep(result)
    ensure
      instrument(:get, path, current_monotonic_ms - start, {}) if defined?(start)
    end

    # @return [Hash, nil]
    def stopwords_get(collection:, id:)
      c = collection.to_s
      s = id.to_s
      ts = typesense
      start = current_monotonic_ms
      path = "/collections/#{c}/stopwords/#{s}"
      result = with_exception_mapping(:get, path, {}, start) do
        ts.collections[c].stopwords[s].retrieve
      end
      symbolize_keys_deep(result)
    rescue Errors::Api => error
      return nil if error.status.to_i == 404

      raise
    ensure
      instrument(:get, path, current_monotonic_ms - start, {}) if defined?(start)
    end

    # @return [Hash]
    def stopwords_delete(collection:, id:)
      c = collection.to_s
      s = id.to_s
      ts = typesense
      start = current_monotonic_ms
      path = "/collections/#{c}/stopwords/#{s}"
      result = with_exception_mapping(:delete, path, {}, start) do
        ts.collections[c].stopwords[s].delete
      end
      symbolize_keys_deep(result)
    ensure
      instrument(:delete, path, current_monotonic_ms - start, {}) if defined?(start)
    end

    # -----------------------------------------------------------------------

    # Bulk import JSONL documents into a collection using Typesense import API.
    #
    # @param collection [String] physical collection name
    # @param jsonl [String] newline-delimited JSON payload
    # @param action [Symbol, String] one of :upsert, :create, :update (default: :upsert)
    # @return [Object] upstream return (String of JSONL statuses or Array of Hashes depending on gem version)
    # @raise [SearchEngine::Errors::*]
    def import_documents(collection:, jsonl:, action: :upsert)
      unless collection.is_a?(String) && !collection.strip.empty?
        raise Errors::InvalidParams, 'collection must be a non-empty String'
      end
      raise Errors::InvalidParams, 'jsonl must be a String' unless jsonl.is_a?(String)

      ts = typesense_for_import
      start = current_monotonic_ms
      path = "/collections/#{collection}/documents/import"

      result = with_exception_mapping(:post, path, {}, start) do
        # The official client accepts (documents, action: "upsert") and appends query params.
        ts.collections[collection].documents.import(jsonl, action: action.to_s)
      end

      instrument(:post, path, current_monotonic_ms - start, {})
      result
    end

    # Delete documents by filter from a collection.
    # @param collection [String] physical collection name
    # @param filter_by [String] Typesense filter string
    # @param timeout_ms [Integer, nil] optional read timeout override in ms
    # @return [Hash] response from Typesense client (symbolized)
    def delete_documents_by_filter(collection:, filter_by:, timeout_ms: nil)
      unless collection.is_a?(String) && !collection.strip.empty?
        raise Errors::InvalidParams, 'collection must be a non-empty String'
      end
      unless filter_by.is_a?(String) && !filter_by.strip.empty?
        raise Errors::InvalidParams, 'filter_by must be a non-empty String'
      end

      ts = timeout_ms&.to_i&.positive? ? build_typesense_client_with_read_timeout(timeout_ms.to_i / 1000.0) : typesense
      start = current_monotonic_ms
      path = "/collections/#{collection}/documents"

      result = with_exception_mapping(:delete, path, {}, start) do
        ts.collections[collection].documents.delete(filter_by: filter_by)
      end

      instrument(:delete, path, current_monotonic_ms - start, {})
      symbolize_keys_deep(result)
    end

    private

    attr_reader :config

    def adapter
      @adapter ||= SearchEngine::Client::HttpAdapter.new(typesense)
    end

    # Remove internal-only keys from the HTTP payload
    def sanitize_body_params(params)
      payload = params.dup
      payload.delete(:_join)
      payload.delete(:_selection)
      payload.delete(:_preset_mode)
      payload.delete(:_preset_pruned_keys)
      payload.delete(:_preset_conflicts)
      payload.delete(:_curation_conflict_type)
      payload.delete(:_curation_conflict_count)
      payload.delete(:_runtime_flags)
      payload.delete(:_hits)
      payload
    end

    # Build the search event payload including selection and preset segments
    def build_search_event_payload(collection:, params:, cache_params: {})
      sel = params[:_selection].is_a?(Hash) ? params[:_selection] : {}
      base = {
        collection: collection,
        params: Observability.redact(params),
        url_opts: Observability.filtered_url_opts(cache_params),
        status: nil,
        error_class: nil,
        retries: nil,
        selection_include_count: sel[:include_count],
        selection_exclude_count: sel[:exclude_count],
        selection_nested_assoc_count: sel[:nested_assoc_count]
      }
      base.merge(build_preset_segment(params)).merge(build_curation_segment(params))
    end

    # Build preset segment (counts/keys only) from compiled params
    # @param params [Hash]
    # @return [Hash]
    def build_preset_segment(params)
      preset_mode = params[:_preset_mode]
      pruned = Array(params[:_preset_pruned_keys]).map { |k| k.respond_to?(:to_sym) ? k.to_sym : k }.grep(Symbol)
      locked_count = begin
        SearchEngine.config.presets.locked_domains.size
      rescue StandardError
        nil
      end
      {
        preset_name: params[:preset],
        preset_mode: preset_mode,
        preset_pruned_keys_count: pruned.empty? ? nil : pruned.size,
        preset_locked_domains_count: locked_count,
        preset_pruned_keys: pruned.empty? ? nil : pruned
      }
    end

    # Build curation segment (counts/flags only) from compiled params
    # @param params [Hash]
    # @return [Hash]
    def build_curation_segment(params)
      # Counts/flags only; IDs/tags redacted. See docs/curation.md.
      pinned_str = params[:pinned_hits].to_s
      hidden_str = params[:hidden_hits].to_s
      tags_str   = params[:override_tags].to_s
      pinned_count = pinned_str.empty? ? 0 : (pinned_str.count(',') + 1)
      hidden_count = hidden_str.empty? ? 0 : (hidden_str.count(',') + 1)
      has_override = !tags_str.empty?
      conflict_type = params[:_curation_conflict_type]
      conflict_count = params[:_curation_conflict_count]
      out = {}
      out[:curation_pinned_count] = pinned_count if pinned_count.positive?
      out[:curation_hidden_count] = hidden_count if hidden_count.positive?
      out[:curation_has_override_tags] = true if has_override
      out[:curation_filter_flag] = params[:filter_curated_hits] if params.key?(:filter_curated_hits)
      out[:curation_conflict_type] = conflict_type.to_s if conflict_type
      out[:curation_conflict_count] = conflict_count if conflict_count
      out
    end

    def typesense
      @typesense ||= build_typesense_client
    end

    def typesense_for_import
      import_timeout = begin
        config.indexer&.timeout_ms
      rescue StandardError
        nil
      end
      if import_timeout&.to_i&.positive? && import_timeout.to_i != config.timeout_ms.to_i
        build_typesense_client_with_read_timeout(import_timeout.to_i / 1000.0)
      else
        typesense
      end
    end

    def build_typesense_client_with_read_timeout(read_timeout_seconds)
      require 'typesense'

      Typesense::Client.new(
        nodes: build_nodes,
        api_key: config.api_key,
        connection_timeout_seconds: (config.open_timeout_ms.to_i / 1000.0),
        read_timeout_seconds: read_timeout_seconds,
        num_retries: config.retries[:attempts].to_i,
        retry_interval_seconds: config.retries[:backoff].to_f,
        logger: safe_logger
      )
    end

    def build_typesense_client
      require 'typesense'

      Typesense::Client.new(
        nodes: build_nodes,
        api_key: config.api_key,
        connection_timeout_seconds: (config.open_timeout_ms.to_i / 1000.0),
        read_timeout_seconds: (config.timeout_ms.to_i / 1000.0),
        num_retries: config.retries[:attempts].to_i,
        retry_interval_seconds: config.retries[:backoff].to_f,
        logger: safe_logger
      )
    end

    def build_nodes
      [
        {
          host: config.host,
          port: config.port,
          protocol: config.protocol
        }
      ]
    end

    def safe_logger
      config.logger
    rescue StandardError
      nil
    end

    def derive_cache_opts(url_opts)
      merged = ClientOptions.url_options_from_config(config)
      merged[:use_cache] = url_opts[:use_cache] if url_opts.key?(:use_cache) && !url_opts[:use_cache].nil?
      merged[:cache_ttl] = Integer(url_opts[:cache_ttl]) if url_opts.key?(:cache_ttl)
      merged
    end

    def validate_single!(collection, params)
      unless collection.is_a?(String) && !collection.strip.empty?
        raise Errors::InvalidParams, 'collection must be a non-empty String'
      end

      raise Errors::InvalidParams, 'params must be a Hash' unless params.is_a?(Hash)
    end

    def validate_multi!(searches)
      unless searches.is_a?(Array) && searches.all? { |s| s.is_a?(Hash) }
        raise Errors::InvalidParams, 'searches must be an Array of Hashes'
      end

      searches.each_with_index do |s, idx|
        unless s.key?(:collection) && s[:collection].is_a?(String) && !s[:collection].strip.empty?
          raise Errors::InvalidParams, "searches[#{idx}][:collection] must be a non-empty String"
        end
      end
    end

    def with_exception_mapping(method, path, cache_params, start_ms)
      yield
    rescue StandardError => error
      map_and_raise(error, method, path, cache_params, start_ms)
    end

    # Map network and API exceptions into stable SearchEngine errors, with
    # redaction and logging.
    def map_and_raise(error, method, path, cache_params, start_ms)
      if error.respond_to?(:http_code)
        status = error.http_code
        body = parse_error_body(error)
        err = Errors::Api.new(
          "typesense api error: #{status}",
          status: status || 500,
          body: body,
          doc: 'docs/client.md#errors',
          details: { http_status: status, body: body.is_a?(String) ? body[0, 120] : body }
        )
        instrument(method, path, current_monotonic_ms - start_ms, cache_params, error_class: err.class.name)
        raise err
      end

      if timeout_error?(error)
        instrument(method, path, current_monotonic_ms - start_ms, cache_params, error_class: Errors::Timeout.name)
        raise Errors::Timeout.new(error.message, doc: 'docs/client.md#errors', details: { op: method, path: path })
      end

      if connection_error?(error)
        instrument(method, path, current_monotonic_ms - start_ms, cache_params, error_class: Errors::Connection.name)
        raise Errors::Connection.new(error.message, doc: 'docs/client.md#errors', details: { op: method, path: path })
      end

      instrument(method, path, current_monotonic_ms - start_ms, cache_params, error_class: error.class.name)
      raise error
    end

    def timeout_error?(error)
      error.is_a?(::Timeout::Error) || error.class.name.include?('Timeout')
    end

    def connection_error?(error)
      return true if error.is_a?(SocketError) || error.is_a?(Errno::ECONNREFUSED) || error.is_a?(Errno::ETIMEDOUT)
      return true if error.class.name.include?('Connection')

      defined?(OpenSSL::SSL::SSLError) && error.is_a?(OpenSSL::SSL::SSLError)
    end

    def instrument(method, path, duration_ms, cache_params, error_class: nil)
      return unless defined?(ActiveSupport::Notifications)

      ActiveSupport::Notifications.instrument(
        'search_engine.request',
        method: method,
        path: path,
        duration_ms: duration_ms,
        url_opts: Observability.filtered_url_opts(cache_params),
        error_class: error_class
      )
    end

    def log_success(method, path, start_ms, cache_params)
      return unless safe_logger

      elapsed = current_monotonic_ms - start_ms
      msg = +'search_engine '
      msg << method.to_s.upcase
      msg << ' '
      msg << path
      msg << ' completed in '
      msg << elapsed.round(1).to_s
      msg << 'ms'
      msg << ' cache='
      msg << (cache_params[:use_cache] ? 'true' : 'false')
      msg << ' ttl='
      msg << cache_params[:cache_ttl].to_s
      safe_logger.info(msg)
    rescue StandardError
      nil
    end

    def parse_error_body(error)
      return error.body if error.respond_to?(:body) && error.body
      return error.message if error.respond_to?(:message) && error.message

      nil
    end

    def current_monotonic_ms
      SearchEngine::Instrumentation.monotonic_ms
    end

    def symbolize_keys_deep(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), h|
          h[k.to_sym] = symbolize_keys_deep(v)
        end
      when Array
        obj.map { |e| symbolize_keys_deep(e) }
      else
        obj
      end
    end
  end
end
