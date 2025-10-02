# frozen_string_literal: true

module SearchEngine
  # Immutable, chainable query relation bound to a model class.
  #
  # Carries normalized query state and provides copy-on-write chainers.
  # All chainers return new frozen instances; no in-place mutation occurs.
  #
  # @example Basic chaining
  #   class Product < SearchEngine::Base; end
  #   r1 = Product.all
  #   r2 = r1.where(category: 'milk').order(:name).limit(10)
  #   r1.object_id != r2.object_id #=> true
  #   r1.empty?                    #=> true
  class Relation
    # Internal normalized state keys
    DEFAULT_STATE = {
      filters: [].freeze,
      ast:     [].freeze, # Predicate AST nodes (authoritative)
      orders:  [].freeze,
      select:  [].freeze,
      limit:   nil,
      offset:  nil,
      page:    nil,
      per_page: nil,
      options: {}.freeze
    }.freeze

    # @return [Class] bound model class (typically a SearchEngine::Base subclass)
    attr_reader :klass

    # Read-only access to accumulated predicate AST nodes.
    #
    # @return [Array<SearchEngine::AST::Node>] a frozen Array of AST nodes
    # @note The returned array is frozen; modifying it will raise.
    def ast
      nodes = Array(@state[:ast])
      nodes.frozen? ? nodes : nodes.dup.freeze
    end

    # Create a new Relation.
    #
    # @param klass [Class] model class the relation is bound to
    # @param state [Hash] optional pre-populated normalized state
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

    # Add filters to the relation.
    #
    # Accepted forms:
    # - Hash: where(id: 1, brand_id: [1,2,3])
    # - Raw string fragment: where("brand_id:=[1,2,3]")
    # - Template with placeholders: where("price > ?", 100)
    #
    # Multiple calls compose with AND semantics (filters accumulate).
    # The relation is immutable; a new instance is returned.
    #
    # @param args [Array<Object>] filter arguments
    # @return [SearchEngine::Relation]
    def where(*args)
      # Build AST nodes for all supported inputs via the DSL parser
      ast_nodes = SearchEngine::DSL::Parser.parse_list(args, klass: @klass)
      # Back-compat: preserve legacy string fragments as well (escape hatch)
      fragments = normalize_where(args)
      spawn do |s|
        s[:ast] = Array(s[:ast]) + Array(ast_nodes)
        s[:filters] = Array(s[:filters]) + fragments
      end
    end

    # Append ordering expressions. Accepts Hash or String forms.
    #
    # Accepted input:
    # - Hash: { field => :asc|:desc, ... }
    # - String: "field:dir" or comma-separated "field:dir,other:asc"
    #
    # Normalization:
    # - Stored as array of strings like ["field:asc", "other:desc"]
    # - Direction lowercased; field trimmed; validation enforced
    # - Dedupe by field with last-wins semantics while preserving last position
    #
    # @param value [Hash, String]
    # @return [SearchEngine::Relation]
    # @raise [ArgumentError] when direction or field is invalid
    def order(value)
      additions = normalize_order(value)
      spawn do |s|
        existing = Array(s[:orders])
        s[:orders] = dedupe_orders_last_wins(existing + additions)
      end
    end

    # Select a subset of fields. De-duplicates and preserves order of first appearance.
    #
    # @param fields [Array<#to_sym,#to_s>]
    # @return [SearchEngine::Relation]
    # @raise [ArgumentError] when fields are blank or unknown for the model
    def select(*fields)
      normalized = normalize_select(fields)
      spawn do |s|
        existing = Array(s[:select])
        s[:select] = (existing + normalized).each_with_object([]) do |f, acc|
          acc << f unless acc.include?(f)
        end
      end
    end

    # Replace the selected fields list (Typesense `include_fields`).
    #
    # Immutably replaces the existing selection with the normalized list of
    # field names. Values are flattened, stripped, coerced to String, blanks
    # dropped, and duplicates removed (preserving first occurrence).
    #
    # @param fields [Array<#to_sym,#to_s>] one or more field identifiers
    # @return [SearchEngine::Relation] a new relation with replaced selection
    # @raise [ArgumentError] when the resulting list is empty, a field is blank,
    #   or a field is unknown for the model when attributes are declared.
    # @example
    #   rel.reselect(:id, :name)
    def reselect(*fields)
      normalized = normalize_select(fields)
      raise ArgumentError, 'reselect: provide at least one non-blank field' if normalized.empty?

      spawn { |s| s[:select] = normalized }
    end

    # Replace all predicates with a new where input.
    #
    # Clears prior predicate state (AST and legacy string fragments) and parses
    # the provided input into a fresh AST using the DSL parser.
    # Accepts the same input forms as {#where}.
    #
    # @param input [Hash, String, Array, Symbol] predicate input
    # @param args [Array<Object>] arguments for template strings
    # @return [SearchEngine::Relation] a new relation with replaced predicates
    # @raise [ArgumentError] when input is missing/blank or produces no predicates
    # @example
    #   rel.rewhere(active: true)
    def rewhere(input, *args)
      if input.nil? || (input.respond_to?(:empty?) && input.empty?) || (input.is_a?(String) && input.strip.empty?)
        raise ArgumentError, 'rewhere: provide a new predicate input'
      end

      nodes = SearchEngine::DSL::Parser.parse(input, klass: @klass, args: args)
      list = Array(nodes).flatten.compact
      raise ArgumentError, 'rewhere: produced no predicates' if list.empty?

      spawn do |s|
        s[:ast] = list
        s[:filters] = []
      end
    end

    # Remove specific pieces of relation state (AR-style unscope).
    #
    # Supported parts and their effects:
    # - :where  => clears AST and legacy filters
    # - :order  => clears orders
    # - :select => clears field selection
    # - :limit  => sets limit to nil
    # - :offset => sets offset to nil
    # - :page   => sets page to nil
    # - :per    => sets per_page to nil
    #
    # @param parts [Array<Symbol,String>] one or more parts to remove
    # @return [SearchEngine::Relation] a new relation with state removed
    # @raise [ArgumentError] when an unsupported part is provided
    # @example
    #   rel.unscope(:order)
    def unscope(*parts)
      symbols = Array(parts).flatten.compact.map(&:to_sym)
      supported = %i[where order select limit offset page per]
      unknown = symbols - supported
      unless unknown.empty?
        raise ArgumentError,
              "unscope: unknown part #{unknown.first.inspect} (supported: #{supported.map(&:inspect).join(', ')})"
      end

      spawn do |s|
        symbols.each do |part|
          case part
          when :where
            s[:ast] = []
            s[:filters] = []
          when :order
            s[:orders] = []
          when :select
            s[:select] = []
          when :limit
            s[:limit] = nil
          when :offset
            s[:offset] = nil
          when :page
            s[:page] = nil
          when :per
            s[:per_page] = nil
          end
        end
      end
    end

    # Set the maximum number of results.
    # @param n [Integer, #to_i, nil]
    # @return [SearchEngine::Relation]
    # @raise [ArgumentError] when n < 1 or not coercible to Integer
    def limit(n)
      value = coerce_integer_min(n, :limit, 1)
      spawn { |s| s[:limit] = value }
    end

    # Set the offset of results.
    # @param n [Integer, #to_i, nil]
    # @return [SearchEngine::Relation]
    # @raise [ArgumentError] when n < 0 or not coercible to Integer
    def offset(n)
      value = coerce_integer_min(n, :offset, 0)
      spawn { |s| s[:offset] = value }
    end

    # Set page number.
    # @param n [Integer, #to_i, nil]
    # @return [SearchEngine::Relation]
    # @raise [ArgumentError] when n < 1 or not coercible to Integer
    def page(n)
      value = coerce_integer_min(n, :page, 1)
      spawn { |s| s[:page] = value }
    end

    # Set per-page size.
    # @param n [Integer, #to_i, nil]
    # @return [SearchEngine::Relation]
    # @raise [ArgumentError] when n < 1 or not coercible to Integer
    def per_page(n)
      value = coerce_integer_min(n, :per, 1)
      spawn { |s| s[:per_page] = value }
    end

    # Convenience alias for per-page size.
    # @param n [Integer, #to_i, nil]
    # @return [SearchEngine::Relation]
    def per(n)
      per_page(n)
    end

    # Shallow-merge options into the relation.
    # For nested hashes, merging is shallow by default.
    # @param opts [Hash]
    # @return [SearchEngine::Relation]
    def options(opts = {})
      raise ArgumentError, 'options must be a Hash' unless opts.is_a?(Hash)

      spawn do |s|
        s[:options] = (s[:options] || {}).merge(opts)
      end
    end

    # True when the relation has no accumulated state beyond defaults.
    # @return [Boolean]
    def empty?
      @state == DEFAULT_STATE
    end

    # Concise single-line inspection containing only non-empty keys.
    # @return [String]
    def inspect
      parts = []
      parts << "Model=#{klass_name_for_inspect}"

      filters = Array(@state[:filters])
      parts << "filters=#{filters.length}" unless filters.empty?

      ast_nodes = Array(@state[:ast])
      parts << "ast=#{ast_nodes.length}" unless ast_nodes.empty?

      compiled = begin
        to_typesense_params
      rescue StandardError
        {}
      end

      sort_str = compiled[:sort_by]
      parts << %(sort="#{truncate_for_inspect(sort_str)}") if sort_str && !sort_str.to_s.empty?

      selected = Array(@state[:select])
      parts << "select=#{selected.length}" unless selected.empty?

      parts << "page=#{compiled[:page]}" if compiled.key?(:page)
      parts << "per=#{compiled[:per_page]}" if compiled.key?(:per_page)

      "#<#{self.class.name} #{parts.join(' ')} >"
    end

    # Compile immutable relation state and options into Typesense body params.
    # The compiler is pure/deterministic and omits URL-level cache knobs.
    #
    # Key insertion order: q, query_by, filter_by, sort_by, include_fields, page, per_page, infix.
    # Empty/nil values are omitted.
    #
    # @return [Hash] typesense body params suitable for Client#search
    # @example
    #   rel.to_typesense_params
    #   # => { q: "*", query_by: "name,description", filter_by: "brand_id:=[1,2] && active:=true", page: 2, per_page: 20 }
    def to_typesense_params
      cfg = SearchEngine.config
      opts = @state[:options] || {}

      params = {}

      # Query basics
      q_val = option_value(opts, :q) || '*'
      query_by_val = option_value(opts, :query_by) || cfg.default_query_by
      params[:q] = q_val
      params[:query_by] = query_by_val if query_by_val

      # Filters and sorting
      ast_nodes = Array(@state[:ast]).flatten.compact
      if !ast_nodes.empty?
        compiled = SearchEngine::Compiler.compile(ast_nodes, klass: @klass)
        params[:filter_by] = compiled unless compiled.to_s.empty?
      else
        filters = Array(@state[:filters])
        params[:filter_by] = filters.join(' && ') unless filters.empty?
      end

      orders = Array(@state[:orders])
      params[:sort_by] = orders.join(',') unless orders.empty?

      # Field selection
      selected = Array(@state[:select])
      params[:include_fields] = selected.join(',') unless selected.empty?

      # Pagination
      pagination = compute_pagination
      params[:page] = pagination[:page] if pagination.key?(:page)
      params[:per_page] = pagination[:per_page] if pagination.key?(:per_page)

      # Keep infix last for stability; include when configured or overridden
      infix_val = option_value(opts, :infix) || cfg.default_infix
      params[:infix] = infix_val if infix_val

      params
    end

    # Convenience alias to compiled body params.
    alias to_h to_typesense_params

    # Materializers
    # --------------
    #
    # Each materializer triggers at most one HTTP request per Relation instance
    # by memoizing the loaded Result. Subsequent calls reuse the memo.

    # Return a shallow copy of hydrated hits.
    # @return [Array<Object>]
    def to_a
      ensure_loaded!
      @__result_memo.to_a
    end

    # Iterate over hydrated hits.
    # @yieldparam obj [Object] hydrated object
    # @return [Enumerator] when no block is given
    def each(&block)
      ensure_loaded!
      return @__result_memo.each unless block_given?

      @__result_memo.each(&block)
    end

    # Return the first element or the first N elements from the loaded page.
    # When +n+ is provided, returns an Array; otherwise returns a single object or nil.
    # @param n [Integer, nil]
    # @return [Object, Array<Object>]
    def first(n = nil)
      ensure_loaded!
      return @__result_memo.to_a.first if n.nil?

      @__result_memo.to_a.first(n)
    end

    # Return the last element or the last N elements from the currently fetched page.
    # Note: operates on the loaded page only; does not trigger additional requests.
    # @param n [Integer, nil]
    # @return [Object, Array<Object>]
    def last(n = nil)
      ensure_loaded!
      return @__result_memo.to_a.last if n.nil?

      @__result_memo.to_a.last(n)
    end

    # Take N elements from the head. When N==1, returns a single object.
    # @param n [Integer]
    # @return [Object, Array<Object>]
    def take(n = 1)
      ensure_loaded!
      return @__result_memo.to_a.first if n == 1

      @__result_memo.to_a.first(n)
    end

    # Convenience for plucking :id values.
    # @return [Array<Object>]
    def ids
      pluck(:id)
    end

    # Pluck one or multiple fields. For a single field, returns a flat Array.
    # For multiple fields, returns an Array of Arrays, preserving field order.
    # Prefers calling readers on hydrated objects when available, otherwise falls
    # back to reading directly from the raw document.
    # @param fields [Array<#to_sym,#to_s>]
    # @return [Array<Object>, Array<Array<Object>>]
    def pluck(*fields)
      raise ArgumentError, 'pluck requires at least one field' if fields.nil? || fields.empty?

      ensure_loaded!
      names = fields.flatten.compact.map(&:to_s)

      raw_hits = Array(@__result_memo.raw['hits'])
      objects = @__result_memo.to_a

      if names.length == 1
        field = names.first
        return objects.each_with_index.map do |obj, idx|
          if obj.respond_to?(field)
            obj.public_send(field)
          else
            doc = (raw_hits[idx] && raw_hits[idx]['document']) || {}
            doc[field]
          end
        end
      end

      # Multiple fields -> array-of-arrays
      objects.each_with_index.map do |obj, idx|
        doc = (raw_hits[idx] && raw_hits[idx]['document']) || {}
        names.map do |field|
          if obj.respond_to?(field)
            obj.public_send(field)
          else
            doc[field]
          end
        end
      end
    end

    # Return total number of matching documents.
    # Uses memoized Result when loaded; otherwise performs a minimal found-only request.
    # @return [Integer]
    def count
      return @__result_memo.found.to_i if @__loaded && @__result_memo

      fetch_found_only
    end

    # Whether any matching documents exist.
    # Uses memoized Result when loaded; otherwise performs a minimal found-only request.
    # @return [Boolean]
    def exists?
      return @__result_memo.found.to_i.positive? if @__loaded && @__result_memo

      fetch_found_only.positive?
    end

    protected

    # Spawn a new relation with a deep-duplicated mutable state.
    # The given block may mutate the provided state Hash (shallow mutations only).
    # Returns a new frozen Relation.
    # @yieldparam state [Hash]
    # @return [SearchEngine::Relation]
    def spawn
      mutable_state = deep_dup(@state)
      yield mutable_state
      self.class.new(@klass, mutable_state)
    end

    private

    def klass_name_for_inspect
      @klass.respond_to?(:name) && @klass.name ? @klass.name : @klass.to_s
    end

    def format_value_for_inspect(value)
      case value
      when Array
        return '[]' if value.empty?

        if value.length <= 3
          value.inspect
        else
          head = value.first(3).map(&:inspect).join(', ')
          "[#{head}... +#{value.length - 3}]"
        end
      when Hash
        return '{}' if value.empty?

        keys = value.keys
        if keys.length <= 3
          value.inspect
        else
          head = keys.first(3).map(&:inspect).join(', ')
          "{#{head}... +#{keys.length - 3} keys}"
        end
      else
        value.inspect
      end
    end

    def normalize_initial_state(state)
      return {} if state.nil? || state.empty?
      raise ArgumentError, 'state must be a Hash' unless state.is_a?(Hash)

      normalized = {}
      state.each do |key, value|
        k = key.to_sym
        case k
        when :filters
          normalized[:filters] = normalize_where(Array(value))
        when :filters_ast
          # Back-compat: accept legacy key and map to :ast
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
        end
      end
      normalized
    end

    # One-time migration: when AST is empty and legacy string filters exist, map
    # each fragment to AST::Raw and prefer AST going forward. Idempotent.
    def migrate_legacy_filters_to_ast!(state)
      return unless state.is_a?(Hash)

      ast_nodes = Array(state[:ast]).flatten.compact
      legacy = Array(state[:filters]).flatten.compact
      return if !ast_nodes.empty? || legacy.empty?

      raw_nodes = legacy.map { |fragment| SearchEngine::AST.raw(String(fragment)) }
      state[:ast] = raw_nodes
    end

    # Normalize where arguments into an array of string fragments safe for Typesense.
    # Supports hash, raw string, and template-with-placeholders.
    def normalize_where(args)
      list = Array(args).flatten.compact
      return [] if list.empty?

      fragments = []
      i = 0
      known_attrs = safe_attributes_map

      while i < list.length
        entry = list[i]
        case entry
        when Hash
          validate_hash_keys!(entry, known_attrs)
          fragments.concat(SearchEngine::Filters::Sanitizer.build_from_hash(entry, known_attrs))
          i += 1
        when String
          if entry.match?(/(?<!\\)\?/) # has unescaped placeholders
            tail = list[(i + 1)..] || []
            needed = SearchEngine::Filters::Sanitizer.count_placeholders(entry)
            args_for_template = tail.first(needed)
            if args_for_template.length != needed # rubocop:disable Metrics/BlockNesting
              raise ArgumentError, "expected #{needed} args for #{needed} placeholders, got #{args_for_template.length}"
            end

            fragments << SearchEngine::Filters::Sanitizer.apply_placeholders(entry, args_for_template)
            i += 1 + needed
          else
            fragments << entry.to_s
            i += 1
          end
        when Symbol
          # Treat symbol as raw string fragment for compatibility
          fragments << entry.to_s
          i += 1
        when Array
          # Recurse over nested arrays
          nested = normalize_where(entry)
          fragments.concat(nested)
          i += 1
        else
          raise ArgumentError, "unsupported where argument of type #{entry.class}"
        end
      end

      fragments
    end

    # Parse and normalize order input into an array of "field:dir" strings.
    def normalize_order(value)
      return [] if value.nil?

      case value
      when Hash
        value.flat_map do |k, dir|
          field = k.to_s.strip
          raise ArgumentError, 'order: field name must be non-empty' if field.empty?

          direction = dir.to_s.strip.downcase
          unless %w[asc desc].include?(direction)
            raise ArgumentError, "order: direction must be :asc or :desc (got #{dir.inspect} for field #{k.inspect})"
          end

          "#{field}:#{direction}"
        end
      when String
        value.split(',').map(&:strip).reject(&:empty?).map do |chunk|
          name, direction = chunk.split(':', 2).map { |p| p.to_s.strip }
          if name.empty? || direction.empty?
            raise ArgumentError, "order: expected 'field:direction' (got #{chunk.inspect})"
          end

          downcased = direction.downcase
          unless %w[asc desc].include?(downcased)
            raise ArgumentError,
                  "order: direction must be :asc or :desc (got #{direction.inspect} for field #{name.inspect})"
          end

          "#{name}:#{downcased}"
        end
      when Array
        # Allow arrays of accepted forms
        value.flat_map { |v| normalize_order(v) }
      when Symbol
        # Back-compat: treat as ascending
        field = value.to_s.strip
        raise ArgumentError, 'order: field name must be non-empty' if field.empty?

        ["#{field}:asc"]
      else
        raise ArgumentError, "order: unsupported input #{value.class}"
      end
    end

    # Dedupe by field with last-wins semantics while preserving last positions.
    def dedupe_orders_last_wins(list)
      return [] if list.nil? || list.empty?

      last_by_field = {}
      list.each_with_index do |entry, idx|
        field, dir = entry.split(':', 2)
        last_by_field[field] = { idx: idx, str: "#{field}:#{dir}" }
      end
      last_by_field.values.sort_by { |h| h[:idx] }.map { |h| h[:str] }
    end

    def normalize_select(fields)
      list = Array(fields).flatten.compact
      return [] if list.empty?

      known_attrs = safe_attributes_map
      known = known_attrs.keys.map(&:to_s)

      ordered = []
      list.each do |f|
        name = f.to_s.strip
        raise ArgumentError, 'select: field names must be non-empty' if name.empty?

        if !known.empty? && !known.include?(name)
          klass_name = klass_name_for_inspect
          known_list = known.sort.join(', ')
          raise ArgumentError, "select: unknown field #{name.inspect} for #{klass_name}. Known: #{known_list}"
        end

        ordered << name unless ordered.include?(name)
      end
      ordered
    end

    def coerce_integer_min(value, name, min)
      return nil if value.nil?

      integer =
        case value
        when Integer then value
        else Integer(value)
        end

      raise ArgumentError, "#{name} must be >= #{min}" if integer < min

      integer
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be an Integer or nil"
    end

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

      klass_name = klass_name_for_inspect
      known_list = known.map(&:to_s).sort.join(', ')
      unknown_name = unknown.first.inspect
      raise ArgumentError, "Unknown attribute #{unknown_name} for #{klass_name}. Known: #{known_list}"
    end

    # Ensure the relation has executed the search and memoized the Result.
    # Thread-safe: double-checked locking around the first load.
    # @return [void]
    def ensure_loaded!
      return if @__loaded && @__result_memo

      @__load_lock.synchronize do
        return if @__loaded && @__result_memo

        execute
      end

      nil
    end

    # Execute the search via the client and memoize the Result.
    #
    # Compiles body params and derives URL/common options by starting from
    # configuration defaults and applying relation-level overrides (whitelisted).
    # Instrumentation is performed by the client to avoid duplicate events.
    #
    # @return [SearchEngine::Result]
    def execute
      collection = collection_name_for_klass
      params = to_typesense_params

      # Start from config defaults, then apply relation-level overrides
      url_opts = ClientOptions.url_options_from_config(SearchEngine.config)
      overrides = build_url_opts
      url_opts.merge!(overrides) unless overrides.empty?

      result = client.search(collection: collection, params: params, url_opts: url_opts)
      @__result_memo = result
      @__loaded = true
      result
    end

    # Perform a minimal request to obtain only the total `found` count.
    # Does not memoize the full Result.
    # @return [Integer]
    def fetch_found_only
      collection = collection_name_for_klass
      base = to_typesense_params

      minimal = base.dup
      minimal[:per_page] = 1
      minimal[:page] = 1
      # Keep include_fields minimal to reduce payload
      minimal[:include_fields] = 'id'

      # Merge config defaults with any relation-level overrides
      url_opts = ClientOptions.url_options_from_config(SearchEngine.config)
      overrides = build_url_opts
      url_opts.merge!(overrides) unless overrides.empty?

      result = client.search(collection: collection, params: minimal, url_opts: url_opts)
      result.found.to_i
    end

    # Compile relation state into Typesense search params.
    # @return [Hash]
    def build_search_params
      to_typesense_params
    end

    # Derive URL/common options for the client request.
    # @return [Hash]
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

    # Compute page and per_page from explicit page/per or limit/offset fallback.
    # Omits pagination keys entirely when nothing is specified.
    # @return [Hash{Symbol=>Integer}]
    def compute_pagination
      page = @state[:page]
      per = @state[:per_page]

      if page || per
        out = {}
        if per && page
          out[:page] = page
          out[:per_page] = per
        elsif per && !page
          out[:page] = 1
          out[:per_page] = per
        elsif page && !per
          out[:page] = page
        end
        return out
      elsif @state[:limit]
        limit = @state[:limit]
        off = @state[:offset] || 0
        computed_page = (off.to_i / limit.to_i) + 1
        return { page: computed_page, per_page: limit }
      end

      {}
    end

    # Resolve the Typesense collection name for the bound class.
    # @return [String]
    def collection_name_for_klass
      return @klass.collection if @klass.respond_to?(:collection) && @klass.collection

      # Fallback: reverse-lookup in registry
      begin
        mapping = SearchEngine::Registry.mapping
        found = mapping.find { |(_, kls)| kls == @klass }
        return found.first if found
      rescue StandardError
        # ignore
      end

      raise ArgumentError, "Unknown collection for #{klass_name_for_inspect}"
    end

    def client
      @__client ||= SearchEngine::Client.new # rubocop:disable Naming/MemoizedInstanceVariableName
    end

    def option_value(hash, key)
      if hash.key?(key)
        hash[key]
      else
        hash[key.to_s]
      end
    end

    def truncate_for_inspect(str, max = 80)
      return str unless str.is_a?(String)
      return str if str.length <= max

      "#{str[0, max]}..."
    end
  end
end
