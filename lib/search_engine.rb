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
    # @param common [Hash] optional params merged into each per-search payload after relation compilation
    # @yieldparam m [SearchEngine::Multi] builder to add labeled relations
    # @return [SearchEngine::Multi::ResultSet]
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

      labels = builder.labels
      payloads = builder.to_payloads(common: common)

      url_opts = SearchEngine::ClientOptions.url_options_from_config(SearchEngine.config)
      raw = SearchEngine::Client.new.multi_search(searches: payloads, url_opts: url_opts)

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

    private

    def config_mutex
      @config_mutex ||= Mutex.new
    end
  end
end
