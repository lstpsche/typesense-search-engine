# frozen_string_literal: true

require 'json'

module SearchEngine
  # Immutable, chainable query relation bound to a model class.
  # See `lib/search_engine/relation.rb` for full API; DX helpers are mixed in here.
  class Relation
    # DX helpers are mixed into `Relation` to offer redaction‑aware, zero‑I/O explain and preview utilities.
    # These helpers are pure and never mutate relation state.
    module Dx
      # Return the request body JSON after compile, fully redacted.
      # @param pretty [Boolean] pretty-print with stable key ordering when true
      # @return [String]
      # @since M8
      # @see docs/dx.md
      def to_params_json(pretty: true)
        params = to_typesense_params
        redacted = redact_body(params)
        if pretty
          ordered = redacted.is_a?(Hash) ? redacted.sort_by { |(k, _v)| k.to_s }.to_h : redacted
          JSON.pretty_generate(ordered)
        else
          JSON.generate(redacted)
        end
      end

      # Return a single-line curl command with redacted API key and JSON body.
      # @return [String]
      # @since M8
      # @see docs/dx.md
      def to_curl
        url = compiled_url
        body_json = JSON.generate(redact_body(to_typesense_params))
        %(curl -X POST #{url} -H 'Content-Type: application/json' -H 'X-TYPESENSE-API-KEY: ***' -d '#{body_json}')
      end

      # Compile and validate without performing network I/O.
      # Returns a structured hash with URL and post-redaction body.
      # @return [Hash] { url:, body:, url_opts: }
      # @raise [SearchEngine::Errors::*] same validation errors as runtime path
      # @since M8
      # @see docs/dx.md
      def dry_run!
        params = to_typesense_params
        body = JSON.generate(redact_body(params))
        { url: compiled_url, body: body, url_opts: compiled_url_opts.freeze }
      end

      # Enhanced explain output with overview, parts, conflicts, and predicted events.
      # Builds a redaction-aware summary without network I/O.
      # @param to [Symbol, nil]
      # @return [String]
      # @since M8
      # @see docs/dx.md#helpers-\u0026-examples
      def explain(to: nil)
        params = to_typesense_params
        lines = []

        lines << header_line
        append_preset_explain_line(lines, params)
        append_curation_explain_lines(lines)
        append_where_line(lines, params)
        append_order_line(lines, params)
        append_group_line(lines)
        append_facets_line(lines, params)
        append_selection_explain_lines(lines, params)
        add_effective_selection_tokens!(lines)
        add_pagination_line!(lines, params)
        lines << overview_line(params)
        append_conflicts_line(lines, params)
        append_events_line(lines, params)

        out = lines.join("\n")
        puts(out) if to == :stdout
        out
      end

      private

      def redact_body(params)
        hash = params.dup
        preview = SearchEngine::Observability.redact(params)
        hash[:filter_by] = preview[:filter_by] if preview.is_a?(Hash) && preview.key?(:filter_by)
        hash
      end

      def predicted_events_for_plan(params)
        events = []
        events << 'search_engine.compile' if Array(@state[:ast]).any?
        events << 'search_engine.joins.compile' if Array(params[:_join] && params[:_join][:assocs]).any?
        events << 'search_engine.grouping.compile' if params.key?(:group_by)
        if preset_name
          events << 'search_engine.preset.apply'
          events << 'search_engine.preset.conflict' if Array(params[:_preset_conflicts]).any?
        end
        events << 'search_engine.search'
        events
      end

      def compiled_url
        collection = collection_name_for_klass
        cfg = SearchEngine.config
        "#{cfg.protocol}://#{cfg.host}:#{cfg.port}/collections/#{collection}/documents/search"
      end

      def compiled_url_opts
        url_opts = ClientOptions.url_options_from_config(SearchEngine.config)
        overrides = build_url_opts
        url_opts.merge!(overrides) unless overrides.empty?
        url_opts
      end

      def header_line
        "#{klass_name_for_inspect} Relation"
      end

      def append_where_line(lines, params)
        fb = params[:filter_by]
        return unless fb && !fb.to_s.strip.empty?

        preview = SearchEngine::Observability.redact(params)
        masked_filter = preview.is_a?(Hash) ? preview[:filter_by].to_s : ''
        where_str = friendly_where(masked_filter)
        lines << "  where: #{where_str}" unless where_str.to_s.strip.empty?
      end

      def append_order_line(lines, params)
        sb = params[:sort_by]
        lines << "  order: #{sb}" if sb && !sb.to_s.strip.empty?
      end

      def append_group_line(lines)
        g = @state[:grouping]
        return unless g

        gparts = ["group_by=#{g[:field]}"]
        gparts << "limit=#{g[:limit]}" if g[:limit]
        gparts << 'missing_values=true' if g[:missing_values]
        lines << "  group: #{gparts.join(' ')}"
      end

      def overview_line(params)
        parts = []
        parts << "collection=#{collection_name_for_klass}"
        if (g = grouping)
          seg = [g[:field]].compact
          seg << "limit=#{g[:limit]}" if g[:limit]
          seg << 'missing_values' if g[:missing_values]
          parts << "grouping=#{seg.join(':')}"
        end
        if params.key?(:page) || params.key?(:per_page)
          p = params[:page]
          per = params[:per_page]
          parts << "page/per=#{p || ''}/#{per || ''}"
        end
        parts << (preset_name ? "preset=#{preset_name}(mode=#{preset_mode})" : 'preset=—')
        parts << "joins=#{Array(joins_list).size}"
        cid = defined?(SearchEngine::Instrumentation) ? SearchEngine::Instrumentation.current_correlation_id : nil
        parts << "cid=#{cid && !cid.to_s.empty? ? cid : '—'}"
        "Overview: #{parts.join(' ')}"
      end

      def append_conflicts_line(lines, params)
        conflicts = Array(params[:_preset_conflicts]).map(&:to_s).sort
        lines << "Conflicts & Warnings: dropped keys in :lock mode => #{conflicts.join(', ')}" unless conflicts.empty?
      end

      def append_events_line(lines, params)
        events = predicted_events_for_plan(params)
        lines << "Events that would fire: #{events.join(' → ')}" unless events.empty?
      end

      def append_facets_line(lines, params)
        fb = params[:facet_by]
        fq = params[:facet_query]
        mv = params[:max_facet_values]
        segs = []
        segs << "facet_by=#{fb}" if fb && !fb.to_s.strip.empty?
        segs << "max=#{mv}" if mv
        segs << "queries=#{fq}" if fq && !fq.to_s.strip.empty?
        lines << "  facets: #{segs.join(' ')}" unless segs.empty?
      end
    end

    include Dx
  end
end
