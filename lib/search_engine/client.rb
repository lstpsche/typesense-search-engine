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
      validate_single!(collection, params)

      cache_params = derive_cache_opts(url_opts)
      ts = typesense

      start = current_monotonic_ms
      payload = params.dup
      path = "/collections/#{collection}/documents/search"

      # Observability event payload (pre-built; redacted)
      if defined?(ActiveSupport::Notifications)
        se_payload = {
          collection: collection,
          params: Observability.redact(params),
          url_opts: Observability.filtered_url_opts(cache_params),
          status: nil,
          error_class: nil,
          retries: nil
        }

        result = nil
        ActiveSupport::Notifications.instrument('search_engine.search', se_payload) do
          result = with_exception_mapping(:post, path, cache_params, start) do
            ts.collections[collection].documents.search(payload, common_params: cache_params)
          end
          se_payload[:status] = :ok
        rescue Errors::Api => error
          se_payload[:status] = error.status
          se_payload[:error_class] = error.class.name
          raise
        rescue Errors::Error => error
          se_payload[:status] = :error
          se_payload[:error_class] = error.class.name
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

    # Execute a federated multi-search request.
    #
    # @param searches [Array<Hash>] each item includes at least :collection and query params
    # @param url_opts [Hash] URL/common knobs (use_cache, cache_ttl)
    # @return [Hash] Parsed response from Typesense multi-search
    # @raise [SearchEngine::Errors::InvalidParams, SearchEngine::Errors::*]
    def multi_search(searches:, url_opts: {})
      validate_multi!(searches)

      cache_params = derive_cache_opts(url_opts)
      ts = typesense

      start = current_monotonic_ms
      path = '/multi_search'
      body = { searches: searches }

      # Observability event payload (pre-built; redacted)
      if defined?(ActiveSupport::Notifications)
        collections = searches.map { |s| s[:collection].to_s }.reject { |c| c.strip.empty? }.uniq
        redacted_params = searches.map { |s| Observability.redact(s) }
        se_payload = {
          collections: collections,
          params: redacted_params,
          url_opts: Observability.filtered_url_opts(cache_params),
          status: nil,
          error_class: nil,
          retries: nil
        }

        result = nil
        ActiveSupport::Notifications.instrument('search_engine.multi_search', se_payload) do
          result = with_exception_mapping(:post, path, cache_params, start) do
            ts.multi_search.perform(body, common_params: cache_params)
          end
          se_payload[:status] = :ok
        rescue Errors::Api => error
          se_payload[:status] = error.status
          se_payload[:error_class] = error.class.name
          raise
        rescue Errors::Error => error
          se_payload[:status] = :error
          se_payload[:error_class] = error.class.name
          raise
        end
      else
        result = with_exception_mapping(:post, path, cache_params, start) do
          ts.multi_search.perform(body, common_params: cache_params)
        end
      end

      duration = current_monotonic_ms - start
      instrument(:post, path, duration, cache_params)
      log_success(:post, path, start, cache_params)
      result
    end

    private

    attr_reader :config

    def typesense
      @typesense ||= build_typesense_client
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
        err = Errors::Api.new("typesense api error: #{status}", status: status || 500, body: body)
        instrument(method, path, current_monotonic_ms - start_ms, cache_params, error_class: err.class.name)
        raise err
      end

      if timeout_error?(error)
        instrument(method, path, current_monotonic_ms - start_ms, cache_params, error_class: Errors::Timeout.name)
        raise Errors::Timeout, error.message
      end

      if connection_error?(error)
        instrument(method, path, current_monotonic_ms - start_ms, cache_params, error_class: Errors::Connection.name)
        raise Errors::Connection, error.message
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
        status: nil,
        duration_ms: duration_ms,
        cache: { use_cache: cache_params[:use_cache], cache_ttl: cache_params[:cache_ttl] },
        error_class: error_class
      )
    rescue StandardError
      nil
    end

    def log_success(method, path, start_ms, cache_params)
      logger = safe_logger
      return unless logger

      duration = current_monotonic_ms - start_ms
      logger.info(
        "[search_engine] #{method.to_s.upcase} #{path} duration_ms=#{duration.round} " \
        "cache.use_cache=#{cache_params[:use_cache]} cache.ttl=#{cache_params[:cache_ttl]}"
      )
    rescue StandardError
      nil
    end

    def parse_error_body(error)
      raw = if error.respond_to?(:http_body)
              error.http_body
            elsif error.respond_to?(:to_s)
              error.to_s
            end
      begin
        require 'json'
        JSON.parse(raw)
      rescue StandardError
        raw
      end
    end

    def current_monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond).to_i
    end
  end
end
