require 'logger'
require 'active_support/notifications'

module SearchEngine
  module Notifications
    # Opt-in compact logging subscriber for SearchEngine AS::Notifications events.
    #
    # Emits concise, single-line log entries with redacted parameters and
    # stable keys. Designed to be lightweight and reloader-safe.
    #
    # Usage:
    #   SearchEngine::Notifications::CompactLogger.subscribe
    #   SearchEngine::Notifications::CompactLogger.unsubscribe
    class CompactLogger
      EVENT_SEARCH = 'search_engine.search'.freeze
      EVENT_MULTI  = 'search_engine.multi_search'.freeze

      # Subscribe to SearchEngine notifications.
      #
      # @param logger [#info,#warn,#error] Logger instance; defaults to config.logger or $stdout
      # @param level [Symbol] one of :debug, :info, :warn, :error
      # @param include_params [Boolean] when true, include whitelisted params for single-search
      # @return [Array<Object>] subscription handles that can be passed to {.unsubscribe}
      def self.subscribe(logger: default_logger, level: :info, include_params: false)
        return [] unless defined?(ActiveSupport::Notifications)

        severity = map_level(level)
        log = logger || default_logger

        search_sub = ActiveSupport::Notifications.subscribe(EVENT_SEARCH) do |*args|
          ev = ActiveSupport::Notifications::Event.new(*args)
          emit_line(log, severity, ev, include_params: include_params, multi: false)
        end

        multi_sub = ActiveSupport::Notifications.subscribe(EVENT_MULTI) do |*args|
          ev = ActiveSupport::Notifications::Event.new(*args)
          emit_line(log, severity, ev, include_params: include_params, multi: true)
        end

        @last_handle = [search_sub, multi_sub]
      end

      # Unsubscribe a previous subscription set.
      # @param handle [Array<Object>, Object, nil] handles returned by {.subscribe}
      # @return [Boolean] true when unsubscribed
      def self.unsubscribe(handle = @last_handle)
        return false unless handle

        Array(handle).each do |sub|
          ActiveSupport::Notifications.unsubscribe(sub)
        end
        @last_handle = nil
        true
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      # Internal: Emit one compact line for a notification event.
      def self.emit_line(logger, severity, event, include_params:, multi:)
        return unless logger
        return unless allow_log?(logger, severity)

        p = event.payload
        duration_ms = event.duration.round(1)

        parts = []
        if multi
          parts << '[se.multi]'
          cols = Array(p[:collections]).join(',')
          parts << "collections=#{cols}" unless cols.empty?
          searches_count = p[:params].is_a?(Array) ? p[:params].size : nil
          parts << "searches=#{searches_count}" if searches_count
        else
          parts << '[se.search]'
          parts << "collection=#{p[:collection]}" if p[:collection]
        end

        parts << "status=#{p[:status] || 'ok'}"
        parts << "duration=#{duration_ms}ms"

        url = p[:url_opts] || {}
        parts << "cache=#{url[:use_cache] ? true : false}"
        parts << "ttl=#{url[:cache_ttl]}" unless url[:cache_ttl].nil?

        if include_params && !multi
          # Only include whitelisted keys for single searches
          params_hash = p[:params].is_a?(Hash) ? p[:params] : {}
          %i[q query_by per_page page infix].each do |key|
            next unless params_hash.key?(key)

            parts << format_param(key, params_hash[key])
          end
          parts << 'filter_by=***' if params_hash.key?(:filter_by)
        end

        line = parts.join(' ')
        log_with_level(logger, severity, line)
      rescue StandardError
        nil
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # Map a Symbol severity to Logger integer constant.
      def self.map_level(level)
        case level.to_s
        when 'debug' then Logger::DEBUG
        when 'info' then Logger::INFO
        when 'warn' then Logger::WARN
        when 'error' then Logger::ERROR
        else Logger::INFO
        end
      end

      # Should we log at this severity for the given logger?
      def self.allow_log?(logger, severity)
        return true unless logger.respond_to?(:level)

        logger.level <= severity
      rescue StandardError
        true
      end

      # Log a message honoring the requested severity.
      def self.log_with_level(logger, severity, line)
        case severity
        when Logger::DEBUG then logger.debug(line)
        when Logger::INFO then logger.info(line)
        when Logger::WARN then logger.warn(line)
        else logger.error(line)
        end
      end

      # Format key=value, quoting strings when they include spaces.
      def self.format_param(key, value)
        if value.is_a?(String)
          %(#{key}="#{value}")
        else
          %(#{key}=#{value})
        end
      end

      # Default logger to stdout when config logger is unavailable.
      def self.default_logger
        cfg_logger = begin
          SearchEngine.config.logger
        rescue StandardError
          nil
        end
        return cfg_logger if cfg_logger

        l = Logger.new($stdout)
        l.level = Logger::INFO
        l
      end

      private_class_method :emit_line, :map_level, :allow_log?, :log_with_level, :format_param, :default_logger
    end
  end
end
