require 'search_engine/version'
require 'search_engine/engine'
require 'search_engine/config'
require 'search_engine/registry'
require 'search_engine/relation'
require 'search_engine/base'
require 'search_engine/filters/sanitizer'

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

    private

    def config_mutex
      @config_mutex ||= Mutex.new
    end
  end
end
