# frozen_string_literal: true

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
      EVENT_SEARCH = 'search_engine.search'
      EVENT_MULTI  = 'search_engine.multi_search'

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

      # Internal: Emit one compact line for a notification event.
      def self.emit_line(logger, severity, event, include_params:, multi:)
        return unless logger
        return unless allow_log?(logger, severity)

        p = event.payload
        duration_ms = event.duration.round(1)

        parts = []
        if multi
          parts.concat(multi_parts(p))
        else
          parts.concat(single_parts(p))
        end

        parts.concat(status_parts(p, duration_ms))
        parts.concat(url_parts(p))

        parts.concat(param_parts(p)) if include_params && !multi

        line = parts.join(' ')
        log_with_level(logger, severity, line)
      rescue StandardError
        nil
      end

      def self.multi_parts(payload)
        labels = Array(payload[:labels]).map(&:to_s)
        labels = Array(payload[:collections]).map(&:to_s) if labels.empty? || labels.all?(&:empty?)
        count = payload[:searches_count]
        count ||= (payload[:params].is_a?(Array) ? payload[:params].size : nil)

        parts = ['[se.multi]']
        parts << "count=#{count}" if count
        parts << "labels=#{labels.join(',')}" unless labels.empty?
        parts
      end
      private_class_method :multi_parts

      def self.single_parts(payload)
        parts = ['[se.search]']
        parts << "collection=#{payload[:collection]}" if payload[:collection]
        parts
      end
      private_class_method :single_parts

      def self.status_parts(payload, duration_ms)
        status_val = payload.key?(:http_status) ? payload[:http_status] : (payload[:status] || 'ok')
        ["status=#{status_val}", "duration=#{duration_ms}ms"]
      end
      private_class_method :status_parts

      def self.url_parts(payload)
        url = payload[:url_opts]
        return [] unless url.is_a?(Hash)

        results = []
        results << "cache=#{url[:use_cache] ? true : false}" if url.key?(:use_cache)
        results << "ttl=#{url[:cache_ttl]}" if url.key?(:cache_ttl)
        results
      end
      private_class_method :url_parts

      def self.param_parts(payload)
        params_hash = payload[:params].is_a?(Hash) ? payload[:params] : {}
        parts = []
        %i[q query_by per_page page infix].each do |key|
          next unless params_hash.key?(key)

          parts << format_param(key, params_hash[key])
        end
        parts << 'filter_by=***' if params_hash.key?(:filter_by)
        parts
      end
      private_class_method :param_parts

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

      # Minimal check for logger level
      def self.allow_log?(logger, severity)
        return true unless logger.respond_to?(:level)

        logger.level <= severity
      end
      private_class_method :allow_log?

      def self.format_param(key, value)
        case key
        when :q then %(q="#{SearchEngine::Observability.truncate_q(value)}")
        else "#{key}=#{value}"
        end
      end
      private_class_method :format_param

      def self.default_logger
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger
        else
          ::Logger.new($stdout)
        end
      end

      def self.log_with_level(logger, severity, line)
        case severity
        when Logger::DEBUG then logger.debug(line)
        when Logger::INFO then logger.info(line)
        when Logger::WARN then logger.warn(line)
        else logger.error(line)
        end
      end
      private_class_method :log_with_level
    end
  end
end
