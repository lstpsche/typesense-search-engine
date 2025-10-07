# frozen_string_literal: true

module SearchEngine
  # Immutable, chainable query relation bound to a model class.
  #
  # Facade wiring that composes State, Options, DSL, Compiler, and Materializers.
  class Relation
    # Keys considered essential for :only preset mode.
    ESSENTIAL_PARAM_KEYS = %i[q page per_page].freeze

    # @return [Class] bound model class (typically a SearchEngine::Base subclass)
    attr_reader :klass

    # Modules are required explicitly to keep require graph stable
    require 'search_engine/relation/state'
    require 'search_engine/relation/options'
    require 'search_engine/relation/dsl'
    require 'search_engine/relation/compiler'
    require 'search_engine/relation/materializers'

    include State
    include Options
    include DSL
    include Compiler
    include Materializers

    # Convenience conversion to compiled body params as a plain Hash.
    def to_h
      v = to_typesense_params
      v.respond_to?(:to_h) ? v.to_h : v
    end

    # Read-only access to accumulated predicate AST nodes.
    # @return [Array<SearchEngine::AST::Node>] a frozen Array of AST nodes
    def ast
      nodes = Array(@state[:ast])
      nodes.frozen? ? nodes : nodes.dup.freeze
    end

    # Return the effective preset mode when a preset is applied.
    # Falls back to :merge when not explicitly set.
    # @return [Symbol]
    def preset_mode
      (@state[:preset_mode] || :merge).to_sym
    end

    # Return the effective preset token (namespaced if configured) or nil.
    # @return [String, nil]
    def preset_name
      @state[:preset_name]
    end

    # Create a new Relation.
    # @param klass [Class]
    # @param state [Hash]
    def initialize(klass, state = {})
      @klass = klass
      normalized = normalize_initial_state(state)
      @state = DEFAULT_STATE.merge(normalized)
      migrate_legacy_filters_to_ast!(@state)
      deep_freeze_inplace(@state)
      @__result_memo = nil
      @__loaded = false
      @__load_lock = Mutex.new
    end

    # Return self for AR-like parity.
    # @return [SearchEngine::Relation]
    def all
      self
    end

    # True when the relation has no accumulated state beyond defaults.
    # @return [Boolean]
    def empty?
      @state == DEFAULT_STATE
    end

    # Console-friendly inspect:
    # - In interactive consoles, execute and render hydrated records for quick preview
    # - In non-interactive contexts, keep a concise summary without I/O
    # @return [String]
    def inspect
      if interactive_console?
        begin
          records = SearchEngine::Hydration::Materializers.to_a(self)
          return "#<#{self.class.name} [#{records.map(&:inspect).join(', ')}]>"
        rescue StandardError
          # fall back to summary below
        end
      end

      summary_inspect_string
    end

    # Explain the current relation without performing any network calls.
    # @return [String]
    def explain(to: nil)
      params = to_typesense_params

      lines = []
      header = "#{klass_name_for_inspect} Relation"
      lines << header

      append_preset_explain_line(lines, params)

      append_curation_explain_lines(lines)

      append_boolean_knobs_explain_lines(lines)

      append_where_and_order_lines(lines, params)

      append_grouping_explain_lines(lines)

      append_selection_explain_lines(lines, params)

      add_effective_selection_tokens!(lines)

      add_pagination_line!(lines, params)

      out = lines.join("\n")
      puts(out) if to == :stdout
      out
    end

    # Read-only list of join association names accumulated on this relation.
    # @return [Array<Symbol>]
    def joins_list
      list = Array(@state[:joins])
      list.frozen? ? list : list.dup.freeze
    end

    # Read-only grouping state for debugging/explain.
    # @return [Hash, nil]
    def grouping
      g = @state[:grouping]
      return nil if g.nil?

      g.frozen? ? g : g.dup.freeze
    end

    # Read-only selected fields state for debugging (base + nested).
    # @return [Hash]
    def selected_fields_state
      base = Array(@state[:select])
      nested = @state[:select_nested] || {}
      order = Array(@state[:select_nested_order])

      {
        base: base.dup.freeze,
        nested: nested.transform_values { |arr| Array(arr).dup.freeze }.freeze,
        nested_order: order.dup.freeze
      }.freeze
    end

    # Programmatic accessor for preset conflicts in :lock mode.
    # @return [Array<Hash{Symbol=>Symbol}>]
    def preset_conflicts
      params = to_typesense_params
      keys = Array(params[:_preset_conflicts]).map { |k| k.respond_to?(:to_sym) ? k.to_sym : k }.grep(Symbol)
      return [].freeze if keys.empty?

      keys.sort.map { |k| { key: k, reason: :locked_by_preset } }.freeze
    end

    # Read-only hit limits state for debugging/explain.
    # @return [Hash, nil]
    def hit_limits
      hl = @state[:hit_limits]
      return nil if hl.nil?

      hl.frozen? ? hl : hl.dup.freeze
    end

    protected

    # Spawn a new relation with a deep-duplicated mutable state.
    # @yieldparam state [Hash]
    # @return [SearchEngine::Relation]
    def spawn
      mutable_state = deep_dup(@state)
      yield mutable_state
      self.class.new(@klass, mutable_state)
    end

    private

    def summary_inspect_string
      parts = []
      parts << "Model=#{klass_name_for_inspect}"

      if (pn = @state[:preset_name])
        pm = @state[:preset_mode] || :merge
        parts << %(preset=#{pn}(mode=#{pm}))
      end

      filters = Array(@state[:filters])
      parts << "filters=#{filters.length}" unless filters.empty?

      ast_nodes = Array(@state[:ast])
      parts << "ast=#{ast_nodes.length}" unless ast_nodes.empty?

      compiled = begin
        SearchEngine::CompiledParams.from(to_typesense_params)
      rescue StandardError
        {}
      end

      sort_str = compiled[:sort_by]
      parts << %(sort="#{truncate_for_inspect(sort_str)}") if sort_str && !sort_str.to_s.empty?

      append_selection_inspect_parts(parts, compiled)

      if (g = @state[:grouping])
        gparts = ["group_by=#{g[:field]}"]
        gparts << "limit=#{g[:limit]}" if g[:limit]
        gparts << 'missing_values=true' if g[:missing_values]
        parts << gparts.join(' ')
      end

      parts << "page=#{compiled[:page]}" if compiled.key?(:page)
      parts << "per=#{compiled[:per_page]}" if compiled.key?(:per_page)

      "#<#{self.class.name} #{parts.join(' ')} >"
    end

    def interactive_console?
      return true if defined?(Rails::Console)
      return true if defined?(IRB) && $stdout.respond_to?(:tty?) && $stdout.tty?
      return true if $PROGRAM_NAME&.end_with?('console')

      false
    end

    def klass_name_for_inspect
      @klass.respond_to?(:name) && @klass.name ? @klass.name : @klass.to_s
    end

    def safe_attributes_map
      if @klass.respond_to?(:attributes)
        @klass.attributes || {}
      else
        {}
      end
    end

    def validate_hash_keys!(hash, attributes_map)
      return if hash.nil? || hash.empty?

      known = attributes_map.keys.map(&:to_sym)
      unknown = hash.keys.map(&:to_sym) - known
      return if unknown.empty?

      begin
        cfg = SearchEngine.config
        return unless cfg.respond_to?(:strict_fields) ? cfg.strict_fields : true
      rescue StandardError
        nil
      end

      klass_name = klass_name_for_inspect
      known_list = known.map(&:to_s).sort.join(', ')
      unknown_name = unknown.first.inspect
      raise ArgumentError, "Unknown attribute #{unknown_name} for #{klass_name}. Known: #{known_list}"
    end

    def collection_name_for_klass
      return @klass.collection if @klass.respond_to?(:collection) && @klass.collection

      begin
        mapping = SearchEngine::Registry.mapping
        found = mapping.find { |(_, kls)| kls == @klass }
        return found.first if found
      rescue StandardError
        nil
      end

      raise ArgumentError, "Unknown collection for #{klass_name_for_inspect}"
    end

    def client
      # Prefer legacy ivar when explicitly set (tests or injected stubs), otherwise memoize with conventional name
      return @__client if instance_variable_defined?(:@__client) && @__client

      @client ||= (SearchEngine.config.respond_to?(:client) && SearchEngine.config.client) || SearchEngine::Client.new
    end

    def build_url_opts
      opts = @state[:options] || {}
      url = {}
      url[:use_cache] = option_value(opts, :use_cache) if opts.key?(:use_cache) || opts.key?('use_cache')
      if opts.key?(:cache_ttl) || opts.key?('cache_ttl')
        url[:cache_ttl] = begin
          Integer(option_value(opts, :cache_ttl))
        rescue StandardError
          nil
        end
      end
      url.compact
    end

    # pluck helpers reside in Materializers

    def curated_indices_for_current_result
      @__result_memo.to_a.each_with_index.select do |obj, _idx|
        obj.respond_to?(:curated_hit?) && obj.curated_hit?
      end.map(&:last)
    end

    def curation_filter_curated_hits?
      @state[:curation] && @state[:curation][:filter_curated_hits]
    end

    def enforce_hit_validator_if_needed!(total_hits, collection: nil)
      hl = @state[:hit_limits]
      return unless hl && hl[:max]

      th = total_hits.to_i
      max = hl[:max].to_i
      return unless th > max && max.positive?

      coll = collection || begin
        collection_name_for_klass
      rescue StandardError
        nil
      end

      msg = "HitLimitExceeded: #{th} results exceed max=#{max}"
      raise SearchEngine::Errors::HitLimitExceeded.new(
        msg,
        hint: 'Increase `validate_hits!(max:)` or narrow filters. Prefer `limit_hits(n)` to avoid work when supported.',
        doc: 'docs/hit_limits.md#validation',
        details: { total_hits: th, max: max, collection: coll, relation_summary: inspect }
      )
    end

    def append_boolean_knobs_explain_lines(lines)
      lines << "  use_synonyms: #{@state[:use_synonyms]}" if @state.key?(:use_synonyms) && !@state[:use_synonyms].nil?
      return unless @state.key?(:use_stopwords) && !@state[:use_stopwords].nil?

      lines << "  use_stopwords: #{@state[:use_stopwords]} (maps to remove_stop_words=#{!@state[:use_stopwords]})"
    end

    def append_where_and_order_lines(lines, params)
      if params[:filter_by] && !params[:filter_by].to_s.strip.empty?
        where_str = friendly_where(params[:filter_by].to_s)
        lines << "  where: #{where_str}"
      end
      lines << "  order: #{params[:sort_by]}" if params[:sort_by] && !params[:sort_by].to_s.strip.empty?
    end

    def append_grouping_explain_lines(lines)
      if (g = @state[:grouping])
        gparts = ["group_by=#{g[:field]}"]
        gparts << "limit=#{g[:limit]}" if g[:limit]
        gparts << 'missing_values=true' if g[:missing_values]
        lines << "  group: #{gparts.join(' ')}"
      end
    end
  end
end
