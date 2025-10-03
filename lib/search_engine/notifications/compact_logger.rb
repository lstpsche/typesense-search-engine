# frozen_string_literal: true

require 'logger'
require 'active_support/notifications'
require 'json'

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
      EVENT_SCHEMA_DIFF   = 'search_engine.schema.diff'
      EVENT_SCHEMA_APPLY  = 'search_engine.schema.apply'
      EVENT_JOINS_COMPILE = 'search_engine.joins.compile'
      EVENT_PARTITION_START  = 'search_engine.indexer.partition_start'
      EVENT_PARTITION_FINISH = 'search_engine.indexer.partition_finish'
      EVENT_BATCH_IMPORT     = 'search_engine.indexer.batch_import'
      EVENT_DELETE_STALE     = 'search_engine.indexer.delete_stale'
      # Legacy (emitted by current codebase): stale_deletes.*
      LEGACY_STALE_STARTED  = 'search_engine.stale_deletes.started'
      LEGACY_STALE_FINISHED = 'search_engine.stale_deletes.finished'
      LEGACY_STALE_ERROR    = 'search_engine.stale_deletes.error'
      LEGACY_STALE_SKIPPED  = 'search_engine.stale_deletes.skipped'

      # Subscribe to SearchEngine notifications.
      #
      # @param logger [#info,#warn,#error] Logger instance; defaults to config.logger or $stdout
      # @param level [Symbol] one of :debug, :info, :warn, :error
      # @param include_params [Boolean] when true, include whitelisted params for single-search
      # @param format [Symbol, nil] :kv or :json; defaults to config.observability.log_format
      # @return [Array<Object>] subscription handles that can be passed to {.unsubscribe}
      def self.subscribe(logger: default_logger, level: :info, include_params: false, format: nil) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        return [] unless defined?(ActiveSupport::Notifications)

        severity = map_level(level)
        log = logger || default_logger
        fmt = (format || (SearchEngine.config.observability&.log_format || :kv)).to_sym

        search_sub = ActiveSupport::Notifications.subscribe(EVENT_SEARCH) do |*args|
          ev = ActiveSupport::Notifications::Event.new(*args)
          emit_line(log, severity, ev, include_params: include_params, multi: false)
        end

        multi_sub = ActiveSupport::Notifications.subscribe(EVENT_MULTI) do |*args|
          ev = ActiveSupport::Notifications::Event.new(*args)
          emit_line(log, severity, ev, include_params: include_params, multi: true)
        end

        schema_diff_sub = ActiveSupport::Notifications.subscribe(EVENT_SCHEMA_DIFF) do |*args|
          ev = ActiveSupport::Notifications::Event.new(*args)
          emit_schema_diff(log, severity, ev, format: fmt)
        end

        schema_apply_sub = ActiveSupport::Notifications.subscribe(EVENT_SCHEMA_APPLY) do |*args|
          ev = ActiveSupport::Notifications::Event.new(*args)
          emit_schema_apply(log, severity, ev, format: fmt)
        end

        joins_compile_sub = ActiveSupport::Notifications.subscribe(EVENT_JOINS_COMPILE) do |*args|
          ev = ActiveSupport::Notifications::Event.new(*args)
          emit_joins_compile(log, severity, ev, format: fmt)
        end

        part_start_sub = ActiveSupport::Notifications.subscribe(EVENT_PARTITION_START) do |*args|
          ev = ActiveSupport::Notifications::Event.new(*args)
          emit_partition_start(log, severity, ev, format: fmt)
        end

        part_finish_sub = ActiveSupport::Notifications.subscribe(EVENT_PARTITION_FINISH) do |*args|
          ev = ActiveSupport::Notifications::Event.new(*args)
          emit_partition_finish(log, severity, ev, format: fmt)
        end

        batch_sub = ActiveSupport::Notifications.subscribe(EVENT_BATCH_IMPORT) do |*args|
          ev = ActiveSupport::Notifications::Event.new(*args)
          emit_batch_import(log, severity, ev, format: fmt)
        end

        stale_sub = ActiveSupport::Notifications.subscribe(EVENT_DELETE_STALE) do |*args|
          ev = ActiveSupport::Notifications::Event.new(*args)
          emit_delete_stale(log, severity, ev, format: fmt)
        end

        # Backward-compat for legacy stale events, map to new formatter
        legacy_started = ActiveSupport::Notifications.subscribe(LEGACY_STALE_STARTED) do |*args|
          ev = ActiveSupport::Notifications::Event.new(*args)
          emit_delete_stale(log, severity, ev, format: fmt, legacy: :started)
        end
        legacy_finished = ActiveSupport::Notifications.subscribe(LEGACY_STALE_FINISHED) do |*args|
          ev = ActiveSupport::Notifications::Event.new(*args)
          emit_delete_stale(log, severity, ev, format: fmt, legacy: :finished)
        end
        legacy_error = ActiveSupport::Notifications.subscribe(LEGACY_STALE_ERROR) do |*args|
          ev = ActiveSupport::Notifications::Event.new(*args)
          emit_delete_stale(log, severity, ev, format: fmt, legacy: :error)
        end
        legacy_skipped = ActiveSupport::Notifications.subscribe(LEGACY_STALE_SKIPPED) do |*args|
          ev = ActiveSupport::Notifications::Event.new(*args)
          emit_delete_stale(log, severity, ev, format: fmt, legacy: :skipped)
        end

        @last_handle = [
          search_sub, multi_sub, schema_diff_sub, schema_apply_sub, joins_compile_sub,
          part_start_sub, part_finish_sub, batch_sub, stale_sub,
          legacy_started, legacy_finished, legacy_error, legacy_skipped
        ]
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
        parts.concat(selection_parts(p)) unless multi
        parts.concat(preset_parts(p)) unless multi

        parts.concat(param_parts(p)) if include_params && !multi

        line = parts.join(' ')
        log_with_level(logger, severity, line)
      rescue StandardError
        nil
      end

      # Schema diff formatter
      def self.emit_schema_diff(logger, severity, event, format: :kv)
        return unless logger
        return unless allow_log?(logger, severity)

        p = event.payload
        h = {
          'event' => 'schema.diff',
          'collection' => p[:collection] || p[:logical],
          'fields.changed' => p[:fields_changed_count],
          'fields.added' => p[:added_count],
          'fields.removed' => p[:removed_count],
          'in_sync' => p[:in_sync],
          'duration.ms' => event.duration.round(1)
        }
        emit(logger, severity, h, format)
      rescue StandardError
        nil
      end

      # Schema apply formatter
      def self.emit_schema_apply(logger, severity, event, format: :kv)
        return unless logger
        return unless allow_log?(logger, severity)

        p = event.payload
        h = {
          'event' => 'schema.apply',
          'collection' => p[:collection] || p[:logical],
          'into' => p[:physical_new] || p[:new_physical],
          'alias_swapped' => p[:alias_swapped],
          'retention_deleted_count' => p[:retention_deleted_count] || p[:dropped_count],
          'status' => p[:status] || 'ok',
          'duration.ms' => event.duration.round(1)
        }
        emit(logger, severity, h, format)
      rescue StandardError
        nil
      end

      # JOINs compile formatter
      # Emits a single-line summary of associations and their usage, with lengths only
      # and without raw filter/include/sort strings.
      def self.emit_joins_compile(logger, severity, event, format: :kv)
        return unless logger
        return unless allow_log?(logger, severity)

        p = event.payload
        used = p[:used_in] || {}
        used_compact = []
        %i[include filter sort].each do |k|
          arr = Array(used[k]).map(&:to_s)
          used_compact << "#{k}:#{arr.join(',')}" unless arr.empty?
        end

        h = {
          'event' => 'joins.compile',
          'collection' => p[:collection],
          'joins.assocs' => Array(p[:assocs]).join(','),
          'joins.count' => p[:join_count],
          'joins.used_in' => used_compact.join('|'),
          'joins.include.len' => p[:include_len],
          'joins.filter.len' => p[:filter_len],
          'joins.sort.len' => p[:sort_len],
          'has_joins' => p[:has_joins],
          'duration.ms' => p[:duration_ms] || event.duration.round(1)
        }
        emit(logger, severity, h.compact, format)
      rescue StandardError
        nil
      end

      def self.emit_partition_start(logger, severity, event, format: :kv)
        return unless logger
        return unless allow_log?(logger, severity)

        p = event.payload
        h = {
          'event' => 'indexer.partition_start',
          'collection' => p[:collection],
          'into' => p[:into],
          'partition' => p[:partition_hash] || p[:partition],
          'dispatch_mode' => p[:dispatch_mode],
          'job_id' => p[:job_id],
          'timestamp' => p[:timestamp]
        }
        emit(logger, severity, h, format)
      rescue StandardError
        nil
      end

      def self.emit_partition_finish(logger, severity, event, format: :kv)
        return unless logger
        return unless allow_log?(logger, severity)

        p = event.payload
        h = {
          'event' => 'indexer.partition_finish',
          'collection' => p[:collection],
          'into' => p[:into],
          'partition' => p[:partition_hash] || p[:partition],
          'batches.total' => p[:batches_total],
          'docs.total' => p[:docs_total],
          'success.total' => p[:success_total],
          'failed.total' => p[:failed_total],
          'status' => p[:status],
          'duration.ms' => event.duration.round(1)
        }
        emit(logger, severity, h, format)
      rescue StandardError
        nil
      end

      def self.emit_batch_import(logger, severity, event, format: :kv)
        return unless logger
        return unless allow_log?(logger, severity)

        p = event.payload
        h = {
          'event' => 'indexer.batch_import',
          'collection' => p[:collection],
          'into' => p[:into],
          'batch_index' => p[:batch_index],
          'docs.count' => p[:docs_count],
          'success.count' => p[:success_count],
          'failure.count' => p[:failure_count],
          'attempts' => p[:attempts],
          'http_status' => p[:http_status],
          'bytes.sent' => p[:bytes_sent],
          'duration.ms' => event.duration.round(1),
          'transient_retry' => p[:transient_retry]
        }
        if SearchEngine.config.observability.include_error_messages && p[:error_sample]
          h['error.sample_count'] = Array(p[:error_sample]).size
          h['message'] =
            SearchEngine::Observability.truncate_message(Array(p[:error_sample]).first,
                                                         SearchEngine.config.observability.max_message_length
                                                        )
        end
        emit(logger, severity, h, format)
      rescue StandardError
        nil
      end

      def self.emit_delete_stale(logger, severity, event, format: :kv, legacy: nil)
        return unless logger
        return unless allow_log?(logger, severity)

        p = normalize_stale_payload(event.payload, legacy: legacy)
        h = {
          'event' => 'indexer.delete_stale',
          'collection' => p[:collection],
          'into' => p[:into],
          'partition' => p[:partition_hash] || p[:partition],
          'filter.hash' => p[:filter_hash],
          'deleted.count' => p[:deleted_count],
          'status' => p[:status] || 'ok',
          'reason' => p[:reason],
          'duration.ms' => p[:duration_ms] || event.duration.round(1)
        }
        emit(logger, severity, h, format)
      rescue StandardError
        nil
      end

      # Emit according to format
      def self.emit(logger, severity, hash, format)
        case format
        when :json
          line = JSON.generate(hash.compact)
          log_with_level(logger, severity, line)
        else
          parts = []
          hash.each do |k, v|
            next if v.nil?

            parts << "#{k}=#{v}"
          end
          log_with_level(logger, severity, parts.join(' '))
        end
      end

      def self.normalize_stale_payload(p, legacy: nil)
        h = p.dup
        case legacy
        when :started
          h[:status] = 'started'
        when :finished
          h[:status] = 'ok'
        when :error
          h[:status] = 'failed'
        when :skipped
          h[:status] = 'skipped'
        end
        h
      end
      private_class_method :normalize_stale_payload

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

      def self.selection_parts(payload)
        inc = (payload[:selection_include_count] || 0).to_i
        exc = (payload[:selection_exclude_count] || 0).to_i
        nest = (payload[:selection_nested_assoc_count] || 0).to_i
        ["sel=I:#{inc}|X:#{exc}|N:#{nest}"]
      end
      private_class_method :selection_parts

      # Compact preset parts for text logs (single-line, allocation-light)
      def self.preset_parts(payload)
        name = payload[:preset_name] || (payload[:params].is_a?(Hash) ? payload[:params][:preset] : nil)
        return [] unless name

        mode = payload[:preset_mode]
        pk_count = (payload[:preset_pruned_keys_count] || Array(payload[:preset_pruned_keys]).size).to_i
        ld_count = payload[:preset_locked_domains_count]
        if ld_count.nil?
          begin
            ld_count = SearchEngine.config.presets.locked_domains.size
          rescue StandardError
            ld_count = 0
          end
        end
        ld_count = ld_count.to_i

        # Token: pz=<name>|m=<mode>|pk=<count>|ld=<count>
        # Truncate name conservatively to keep line short
        shown_name = name.to_s
        shown_name = shown_name.length > 64 ? "#{shown_name[0, 64]}…" : shown_name

        parts = ["pz=#{shown_name}"]
        parts << "m=#{mode}" if mode
        parts << "pk=#{pk_count}" if pk_count.positive?
        parts << "ld=#{ld_count}" if ld_count.positive?

        # Optionally include small list of pruned keys when small (<=3)
        keys = Array(payload[:preset_pruned_keys]).map { |k| k.respond_to?(:to_sym) ? k.to_sym : k }.grep(Symbol)
        parts << "pk=[#{keys.map(&:to_s).join(',')}]" if keys.size.positive? && keys.size <= 3

        [parts.join('|')]
      rescue StandardError
        []
      end
      private_class_method :preset_parts

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

      # Build JSON object for search/multi events
      def self.build_json_hash(payload, duration_ms:, multi:, include_params: false) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
        if multi
          labels = Array(payload[:labels]).map(&:to_s)
          labels = Array(payload[:collections]).map(&:to_s) if labels.empty? || labels.all?(&:empty?)
          {
            'event' => 'multi',
            'labels' => (labels unless labels.empty?),
            'count' => payload[:searches_count] || (payload[:params].is_a?(Array) ? payload[:params].size : nil),
            'status' => payload[:http_status] || payload[:status] || 'ok',
            'duration.ms' => duration_ms,
            'cache' => extract_cache_flag(payload[:url_opts]),
            'ttl' => extract_ttl(payload[:url_opts])
          }.compact
        else
          params_hash = payload[:params].is_a?(Hash) ? payload[:params] : {}
          h = {
            'event' => 'search',
            'collection' => payload[:collection],
            'status' => payload[:http_status] || payload[:status] || 'ok',
            'duration.ms' => duration_ms,
            'cache' => extract_cache_flag(payload[:url_opts]),
            'ttl' => extract_ttl(payload[:url_opts]),
            'selection_include_count' => (payload[:selection_include_count] || 0).to_i,
            'selection_exclude_count' => (payload[:selection_exclude_count] || 0).to_i,
            'selection_nested_assoc_count' => (payload[:selection_nested_assoc_count] || 0).to_i,
            'preset_name' => payload[:preset_name],
            'preset_mode' => payload[:preset_mode],
            'preset_pruned_keys_count' => payload[:preset_pruned_keys_count],
            'preset_locked_domains_count' => payload[:preset_locked_domains_count],
            'preset_pruned_keys' => begin
              arr = Array(payload[:preset_pruned_keys])
              arr.empty? ? nil : arr.map(&:to_s)
            end
          }
          # Grouping fields at top-level when present
          h['group_by'] = params_hash[:group_by] if params_hash.key?(:group_by)
          h['group_limit'] = params_hash[:group_limit] if params_hash.key?(:group_limit)
          h['group_missing_values'] = true if params_hash[:group_missing_values]

          if include_params
            %i[q query_by per_page page infix].each do |key|
              h[key.to_s] = params_hash[key] if params_hash.key?(key)
            end
            h['filter_by'] = '***' if params_hash.key?(:filter_by)
          end
          h.compact
        end
      end
      private_class_method :build_json_hash

      def self.extract_cache_flag(url_opts)
        return nil unless url_opts.is_a?(Hash)

        url_opts[:use_cache] ? true : false
      end
      private_class_method :extract_cache_flag

      def self.extract_ttl(url_opts)
        return nil unless url_opts.is_a?(Hash)

        url_opts[:cache_ttl]
      end
      private_class_method :extract_ttl
    end
  end
end
