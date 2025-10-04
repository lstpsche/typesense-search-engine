# frozen_string_literal: true

require 'json'
require 'active_support/notifications'

module SearchEngine
  # Structured logging subscriber for unified instrumentation events.
  #
  # Consumes events emitted via {SearchEngine::Instrumentation.instrument}
  # and writes either a compact single-line entry or a JSON object per event.
  #
  # Configuration:
  #
  #   SearchEngine.configure do |c|
  #     c.logging = OpenStruct.new(mode: :compact, level: :info, sample: 1.0, logger: Rails.logger)
  #   end
  #
  # Modes: :compact (default) or :json. Supports sampling and opt-out via
  # sample: 0.0 or mode: nil.
  module LoggingSubscriber
    class << self
      # Install the subscriber in a reloader-safe and idempotent way.
      #
      # @param config [#mode,#level,#sample,#logger,nil]
      # @return [Object, nil] subscription handle
      def install!(config = nil)
        uninstall!

        cfg = normalize_config(config)
        return nil if cfg[:mode].nil? || cfg[:sample] <= 0.0
        return nil unless defined?(ActiveSupport::Notifications)

        @mode = cfg[:mode]
        @level = cfg[:level]
        @logger = cfg[:logger]
        @sample = cfg[:sample]

        @handle = ActiveSupport::Notifications.subscribe(/^search_engine\./) do |*args|
          # Fast sampling decision before formatting or allocations beyond Event
          next unless sampled?(@sample)

          event = ActiveSupport::Notifications::Event.new(*args)
          begin
            log_line = (@mode == :json ? format_json(event) : format_compact(event))
            emit(@logger, @level, log_line)
          rescue StandardError
            # Never raise from logging
            nil
          end
        end
      end

      # Uninstall previously installed subscriber.
      # @return [Boolean]
      def uninstall!
        return false unless defined?(ActiveSupport::Notifications)
        return false unless @handle

        ActiveSupport::Notifications.unsubscribe(@handle)
        @handle = nil
        true
      end

      private

      def normalize_config(config)
        c = config || (SearchEngine.respond_to?(:config) ? SearchEngine.config.logging : nil)
        logger =
          if c.respond_to?(:logger) && c.logger
            c.logger
          elsif SearchEngine.respond_to?(:config) && SearchEngine.config&.logger
            SearchEngine.config.logger
          else
            require 'logger'
            Logger.new($stdout)
          end

        mode = c&.mode || :compact
        level = c&.level || :info
        sample = begin
          val = c&.sample
          val = 1.0 if val.nil?
          val = 0.0 if val.respond_to?(:to_f) && val.to_f.negative?
          val = 1.0 if val.respond_to?(:to_f) && val.to_f > 1.0
          val.to_f
        rescue StandardError
          1.0
        end

        { mode: mode&.to_sym, level: level.to_sym, sample: sample, logger: logger }
      end

      def emit(logger, level, line)
        return unless logger && level && line

        if logger.respond_to?(level)
          logger.public_send(level, line)
        elsif logger.respond_to?(:add)
          # Fallback: map to Logger::Severity if available
          sev = severity_map[level] || severity_map[:info]
          logger.add(sev, line)
        end
      end

      def severity_map
        @severity_map ||= if defined?(::Logger)
                            {
                              debug: ::Logger::DEBUG,
                              info: ::Logger::INFO,
                              warn: ::Logger::WARN,
                              error: ::Logger::ERROR,
                              fatal: ::Logger::FATAL
                            }
                          else
                            { debug: 0, info: 1, warn: 2, error: 3, fatal: 4 }
                          end
      end

      def sampled?(rate)
        return false if rate <= 0.0
        return true if rate >= 1.0

        rng = (Thread.current[:__se_log_rng__] ||= Random.new)
        rng.rand < rate
      end

      # --- Formatting helpers ---

      EM_DASH = '—'

      def format_compact(event)
        p = event.payload || {}
        name = event.name
        short = name.sub(/^search_engine\./, 'se.')
        cid = short_correlation_id(p[:correlation_id])
        duration = safe_duration(event, p)
        status = pick_status(p)
        collection = p[:collection] || p[:logical]

        groups = value_or_dash(p[:groups_count])
        preset = p[:preset_name] || value_or_dash(nil)
        pinned = p[:curation_pinned_count] || p[:pinned_count] || 0
        hidden = p[:curation_hidden_count] || p[:hidden_count] || 0

        parts = []
        parts << "[#{short}]"
        parts << "id=#{cid}"
        parts << "coll=#{collection}" if collection
        parts << "status=#{status}"
        parts << "dur=#{duration}ms"
        parts << "groups=#{groups}"
        parts << "preset=#{preset}"
        parts << "cur=#{pinned}/#{hidden}"
        parts.join(' ')
      end

      def format_json(event)
        p = event.payload || {}
        duration = safe_duration(event, p)
        cid = short_correlation_id(p[:correlation_id])
        status = pick_status(p)

        h = {}
        h['event'] = event.name
        h['cid'] = cid
        h['collection'] = (p[:collection] || p[:logical]) if p[:collection] || p[:logical]
        h['status'] = status
        h['duration_ms'] = duration

        # domain extras (optional)
        h['group_count'] = p[:groups_count] if p.key?(:groups_count)
        h['preset_mode'] = p[:preset_mode] if p.key?(:preset_mode)
        if p.key?(:curation_pinned_count) || p.key?(:pinned_count)
          h['curation_pinned_count'] =
            (p[:curation_pinned_count] || p[:pinned_count])
        end
        if p.key?(:curation_hidden_count) || p.key?(:hidden_count)
          h['curation_hidden_count'] =
            (p[:curation_hidden_count] || p[:hidden_count])
        end

        # Do not include raw params. If a preview is present and already redacted, include a tiny count only.
        if p.key?(:params_preview)
          preview = p[:params_preview]
          preview = SearchEngine::Instrumentation.redact(preview)
          h['params_preview_keys'] = (preview.is_a?(Hash) ? preview.keys.size : nil)
        end

        JSON.generate(safe_jsonable(h))
      rescue StandardError
        # As a last resort, log a minimal JSON line
        JSON.generate({ 'event' => event.name, 'cid' => cid, 'status' => status, 'duration_ms' => duration })
      end

      def safe_duration(event, payload)
        d = (event.respond_to?(:duration) ? event.duration : payload[:duration_ms]).to_f
        d = payload[:duration_ms].to_f if d.zero? && payload[:duration_ms]
        d.round(1)
      end

      def pick_status(payload)
        payload.key?(:http_status) ? payload[:http_status] : (payload[:status] || 'ok')
      end

      def short_correlation_id(cid)
        str = cid.to_s
        return random_hex4 if str.empty?

        str[0, 4]
      end

      def random_hex4
        rng = (Thread.current[:__se_log_rng__] ||= Random.new)
        val = rng.rand(0x10000)
        val.to_s(16).rjust(4, '0')
      end

      def value_or_dash(v)
        v.nil? || (v.respond_to?(:empty?) && v.empty?) ? EM_DASH : v
      end

      def safe_jsonable(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), h|
            h[k.to_s] = safe_jsonable(v)
          end
        when Array
          obj.map { |v| safe_jsonable(v) }
        when Numeric, TrueClass, FalseClass, NilClass
          obj
        else
          obj.to_s
        end
      end
    end
  end
end
