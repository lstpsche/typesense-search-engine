# frozen_string_literal: true

module SearchEngine
  class Relation
    # Canonical immutable state helpers and defaults for Relation.
    # Owns deep-freeze and duplication utilities, plus initial state normalization.
    module State
      # Internal normalized state keys (authoritative defaults)
      DEFAULT_STATE = {
        filters: [].freeze,
        ast:     [].freeze,
        orders:  [].freeze,
        select:  [].freeze,
        select_nested: {}.freeze,
        select_nested_order: [].freeze,
        exclude: [].freeze,
        exclude_nested: {}.freeze,
        exclude_nested_order: [].freeze,
        joins:   [].freeze,
        limit:   nil,
        offset:  nil,
        page:    nil,
        per_page: nil,
        grouping: nil,
        options: {}.freeze,
        preset_name: nil,
        preset_mode: nil,
        facet_fields: [].freeze,
        facet_max_values: [].freeze,
        facet_queries: [].freeze,
        highlight: {}.freeze,
        highlight_fields: [].freeze,
        highlight_full_fields: [].freeze,
        highlight_start_tag: nil,
        highlight_end_tag: nil,
        highlight_affix_num_tokens: nil,
        highlight_snippet_threshold: nil,
        use_synonyms: nil,
        use_stopwords: nil,
        ranking: nil,
        hit_limits: {}.freeze
      }.freeze

      # Normalize the provided initial state Hash using the Relation's normalizers.
      # @param state [Hash]
      # @return [Hash]
      def normalize_initial_state(state)
        return {} if state.nil? || state.empty?
        raise ArgumentError, 'state must be a Hash' unless state.is_a?(Hash)

        normalized = {}
        state.each { |key, value| apply_initial_state_key!(normalized, key, value) }
        normalized
      end

      # Apply a single initial state key with normalization.
      # Delegates to the same normalizers used by DSL chainers.
      # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/MethodLength
      def apply_initial_state_key!(normalized, key, value)
        k = key.to_sym
        case k
        when :filters
          normalized[:filters] = normalize_where(Array(value))
        when :filters_ast
          nodes = Array(value).flatten.compact
          normalized[:ast] ||= []
          normalized[:ast] += if nodes.all? { |n| n.is_a?(SearchEngine::AST::Node) }
                                nodes
                              else
                                SearchEngine::DSL::Parser.parse_list(nodes, klass: @klass)
                              end
        when :ast
          nodes = Array(value).flatten.compact
          normalized[:ast] = if nodes.all? { |n| n.is_a?(SearchEngine::AST::Node) }
                               nodes
                             else
                               SearchEngine::DSL::Parser.parse_list(nodes, klass: @klass)
                             end
        when :orders
          normalized[:orders] = normalize_order(value)
        when :select
          normalized[:select] = normalize_select(Array(value))
        when :select_nested
          normalized[:select_nested] = (value || {})
        when :select_nested_order
          normalized[:select_nested_order] = Array(value).flatten.compact.map(&:to_sym)
        when :exclude
          normalized[:exclude] = normalize_select(Array(value))
        when :exclude_nested
          normalized[:exclude_nested] = (value || {})
        when :exclude_nested_order
          normalized[:exclude_nested_order] = Array(value).flatten.compact.map(&:to_sym)
        when :joins
          normalized[:joins] = normalize_joins(Array(value))
        when :limit
          normalized[:limit] = coerce_integer_min(value, :limit, 1)
        when :offset
          normalized[:offset] = coerce_integer_min(value, :offset, 0)
        when :page
          normalized[:page] = coerce_integer_min(value, :page, 1)
        when :per_page
          normalized[:per_page] = coerce_integer_min(value, :per, 1)
        when :options
          normalized[:options] = (value || {}).dup
        when :grouping
          normalized[:grouping] = normalize_grouping(value)
        when :preset_name
          normalized[:preset_name] = value&.to_s&.strip
        when :preset_mode
          normalized[:preset_mode] = value&.to_sym
        when :curation
          normalized[:curation] = normalize_curation_input(value)
        when :facet_fields
          normalized[:facet_fields] = Array(value).flatten.compact
        when :facet_max_values
          normalized[:facet_max_values] = Array(value).flatten.compact
        when :facet_queries
          normalized[:facet_queries] = Array(value).flatten.compact
        when :highlight
          normalized[:highlight] = normalize_highlight_input(value)
        when :ranking
          normalized[:ranking] = normalize_ranking_input(value || {})
        when :hit_limits
          normalized[:hit_limits] = normalize_hit_limits_input(value || {})
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/MethodLength

      # One-time migration: when AST is empty and legacy string filters exist, map legacy to AST::Raw.
      # Idempotent and safe for repeated calls.
      # @param state [Hash]
      # @return [void]
      def migrate_legacy_filters_to_ast!(state)
        return unless state.is_a?(Hash)

        ast_nodes = Array(state[:ast]).flatten.compact
        legacy = Array(state[:filters]).flatten.compact
        return if !ast_nodes.empty? || legacy.empty?

        raw_nodes = legacy.map { |fragment| SearchEngine::AST.raw(String(fragment)) }
        state[:ast] = raw_nodes
        nil
      end

      # Deep duplicate Hash/Array trees; leaves are returned as-is.
      # @param obj [Object]
      # @return [Object]
      def deep_dup(obj)
        case obj
        when Hash
          obj.transform_values(&method(:deep_dup))
        when Array
          obj.map(&method(:deep_dup))
        else
          obj
        end
      end

      # Deep-freeze Hash/Array/String trees in-place; returns the frozen object.
      # @param obj [Object]
      # @return [Object]
      def deep_freeze_inplace(obj)
        case obj
        when Hash
          obj.each_value { |v| deep_freeze_inplace(v) }
          obj.freeze
        when Array
          obj.each { |el| deep_freeze_inplace(el) }
          obj.freeze
        else
          obj.freeze if obj.is_a?(String)
        end
        obj
      end
    end
  end
end
