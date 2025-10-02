# frozen_string_literal: true

require 'search_engine/version'
require 'search_engine/engine'
require 'search_engine/config'
require 'search_engine/errors'
require 'search_engine/registry'
require 'search_engine/relation'
require 'search_engine/base'
require 'search_engine/result'
require 'search_engine/filters/sanitizer'
require 'search_engine/ast'
require 'search_engine/dsl/parser'
require 'search_engine/compiler'
require 'search_engine/multi'
require 'search_engine/client_options'

# Top-level namespace for the SearchEngine gem.
# Provides Typesense integration points for Rails applications.
module SearchEngine
  class << self
    # Access the singleton configuration instance.
    # @return [SearchEngine::Config]
    def config
      @config ||= Config.new
    end

    # Configure the engine in a thread-safe manner.
    #
    # @yieldparam c [SearchEngine::Config]
    # @return [SearchEngine::Config]
    def configure
      raise ArgumentError, 'block required' unless block_given?

      config_mutex.synchronize do
        yield config
        config.validate!
      end
      config
    end

    # Execute a federated multi-search using the Multi builder.
    #
    # Builds and executes a multi-search request, returning a
    # {SearchEngine::Multi::ResultSet} that maps results back to labels.
    # Enforces the configured {SearchEngine::Config#multi_search_limit} before
    # making any network calls.
    #
    # @param common [Hash] optional params merged into each per-search payload after relation compilation
    # @yieldparam m [SearchEngine::Multi] builder to add labeled relations
    # @return [SearchEngine::Multi::ResultSet]
    # @raise [ArgumentError] when the number of searches exceeds the configured limit
    # @example
    #   res = SearchEngine.multi_search(common: { query_by: SearchEngine.config.default_query_by }) do |m|
    #     m.add :products, Product.all.where(active: true).per(10)
    #     m.add :brands,   Brand.all.where('name:~rud').per(5)
    #   end
    #   res[:products].found
    def multi_search(common: {})
      raise ArgumentError, 'block required' unless block_given?

      builder = SearchEngine::Multi.new
      yield builder

      # Enforce maximum number of searches before compiling/dispatch
      count = builder.labels.size
      limit = SearchEngine.config.multi_search_limit
      if count > limit
        raise ArgumentError,
              "multi_search: #{count} searches exceed limit (#{limit}). " \
              'Increase `SearchEngine.config.multi_search_limit` if necessary.'
      end

      labels = builder.labels
      payloads = builder.to_payloads(common: common)

      url_opts = SearchEngine::ClientOptions.url_options_from_config(SearchEngine.config)
      raw = begin
        SearchEngine::Client.new.multi_search(searches: payloads, url_opts: url_opts)
      rescue Errors::Api => error
        raise augment_multi_api_error(error, labels)
      end

      # Typesense returns a Hash with key 'results' => [ { ... }, ... ]
      list = Array(raw && raw['results'])
      pairs = []
      list.each_with_index do |item, idx|
        label = labels[idx]
        klass = builder.klasses[idx]
        result = SearchEngine::Result.new(item, klass: klass)
        pairs << [label, result]
      end

      SearchEngine::Multi::ResultSet.new(pairs)
    end

    # Execute a federated multi-search and return the raw response.
    #
    # This helper mirrors {.multi_search} but returns the raw Hash returned by
    # the underlying client. It enforces the configured limit and augments API
    # error messages with label context when possible.
    #
    # @param common [Hash] optional params merged into each per-search payload after relation compilation
    # @yieldparam m [SearchEngine::Multi] builder to add labeled relations
    # @return [Hash] Raw Typesense multi-search response
    # @raise [ArgumentError] when the number of searches exceeds the configured limit
    # @raise [SearchEngine::Errors::Api] when Typesense returns a non-2xx status
    def multi_search_raw(common: {})
      raise ArgumentError, 'block required' unless block_given?

      builder = SearchEngine::Multi.new
      yield builder

      count = builder.labels.size
      limit = SearchEngine.config.multi_search_limit
      if count > limit
        raise ArgumentError,
              "multi_search: #{count} searches exceed limit (#{limit}). " \
              'Increase `SearchEngine.config.multi_search_limit` if necessary.'
      end

      labels = builder.labels
      payloads = builder.to_payloads(common: common)

      url_opts = SearchEngine::ClientOptions.url_options_from_config(SearchEngine.config)
      SearchEngine::Client.new.multi_search(searches: payloads, url_opts: url_opts)
    rescue Errors::Api => error
      raise augment_multi_api_error(error, labels)
    end

    private

    def config_mutex
      @config_mutex ||= Mutex.new
    end

    # Build an API error with additional label context when possible.
    # @param error [SearchEngine::Errors::Api]
    # @param labels [Array<Symbol>] ordered labels for the search list
    # @return [SearchEngine::Errors::Api]
    def augment_multi_api_error(error, labels)
      label_msg = nil
      if error.respond_to?(:body) && error.body.is_a?(Hash)
        results = error.body['results'] || error.body[:results]
        if results.is_a?(Array)
          failing_index = nil
          failing_status = nil
          results.each_with_index do |item, idx|
            code = item.is_a?(Hash) ? (item['status'] || item[:status] || item['code'] || item[:code]) : nil
            next if code.nil? || code.to_i == 200

            failing_index = idx
            failing_status = code.to_i
            break
          end
          if !failing_index.nil? && labels[failing_index]
            label_msg = " for label :#{labels[failing_index]} (status #{failing_status})"
          end
        end
      end

      base = error.message.to_s
      suffix = if label_msg
                 " Multi-search failed#{label_msg}."
               else
                 " Multi-search failed for #{labels.size} searches (status " \
                 "#{error.status}). Label-level context unavailable."
               end

      Errors::Api.new("#{base}#{suffix}", status: error.status, body: error.body)
    rescue StandardError
      error
    end
  end
end
