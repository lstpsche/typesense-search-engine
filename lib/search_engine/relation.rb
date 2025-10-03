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
      # Nested include_fields selection state
      select_nested: {}.freeze,           # { assoc(Symbol) => [field(String), ...] }
      select_nested_order: [].freeze,     # [assoc(Symbol), ...] first-mention order
      joins:   [].freeze,
      limit:   nil,
      offset:  nil,
      page:    nil,
      per_page: nil,
      grouping: nil,
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
    # - Joined Hash: where(authors: { last_name: "Rowling" })
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
      ast_nodes = SearchEngine::DSL::Parser.parse_list(args, klass: @klass, joins: joins_list)
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
    # - Hash: { field => :asc|:desc, ... } or { assoc => { field => :asc|:desc } }
    # - String: "field:dir" or comma-separated "field:dir,other:asc"
    #
    # Normalization:
    # - Stored as array of strings like ["field:asc", "$assoc.field:desc"]
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

    # Select a subset of fields for Typesense `include_fields`.
    #
    # Accepts a mix of base fields and nested association fields using a Ruby-ish shape.
    #
    # - Base fields: symbols/strings, e.g. `:id, "title"`
    # - Nested: a Hash mapping association name => field list, e.g. `{ authors: [:first_name, :last_name] }`
    # - Arrays are flattened; blanks are dropped; duplicates are removed preserving first occurrence order
    # - Associations are validated against the model's `joins_config`
    #
    # Multiple calls merge:
    # - Base fields: first-mention order wins; later calls append new unique fields only
    # - Nested per-association: first-mention order wins; later calls append new unique fields only
    # - Association emission order is by first mention across calls
    #
    # The relation is immutable; a new instance is returned.
    #
    # @param fields [Array<Symbol,String,Hash,Array>]
    # @return [SearchEngine::Relation]
    # @raise [ArgumentError] when inputs are invalid or field names are blank
    # @raise [SearchEngine::Errors::UnknownJoin] when a nested association is not declared
    def select(*fields)
      normalized = normalize_select_input(fields)
      spawn do |s|
        # Merge base fields with first-wins semantics
        existing_base = Array(s[:select])
        merged_base = (existing_base + normalized[:base]).each_with_object([]) do |f, acc|
          acc << f unless acc.include?(f)
        end
        s[:select] = merged_base

        # Merge nested selections preserving association first-mention order
        existing_nested = s[:select_nested] || {}
        existing_order = Array(s[:select_nested_order])

        normalized[:nested_order].each do |assoc|
          new_fields = Array(normalized[:nested][assoc])
          next if new_fields.empty?

          old_fields = Array(existing_nested[assoc])
          merged_fields = (old_fields + new_fields).each_with_object([]) do |name, acc|
            acc << name unless acc.include?(name)
          end
          existing_nested = existing_nested.merge(assoc => merged_fields)
          existing_order << assoc unless existing_order.include?(assoc)
        end

        s[:select_nested] = existing_nested
        s[:select_nested_order] = existing_order
      end
    end

    # Convenience alias for `select` supporting nested include_fields input.
    #
    # @see #select
    # @param fields [Array]
    # @return [SearchEngine::Relation]
    def include_fields(*fields)
      select(*fields)
    end

    # Group results by a single field with optional limit and missing values policy.
    #
    # Stores normalized immutable grouping state under `@state[:grouping]`.
    # Subsequent calls replace the existing grouping state (last call wins).
    #
    # @param field [Symbol, String] field name to group by (base field only)
    # @param limit [Integer, nil] optional positive limit for number of hits per group
    # @param missing_values [Boolean] whether to include missing values as their own group
    # @return [SearchEngine::Relation] a new relation with grouping applied
    # @raise [SearchEngine::Errors::InvalidGroup] when inputs are invalid or field is unknown
    # @raise [SearchEngine::Errors::UnsupportedGroupField] when a joined/path field is provided (unsupported)
    # @example
    #   SearchEngine::Product
    #     .group_by(:brand_id, limit: 1, missing_values: true)
    #     .where(active: true)
    #     .order(updated_at: :desc)
    def group_by(field, limit: nil, missing_values: false)
      normalized = normalize_grouping(field: field, limit: limit, missing_values: missing_values)

      rel = spawn do |s|
        s[:grouping] = normalized
      end

      if defined?(SearchEngine::Instrumentation)
        begin
          payload = {
            collection: klass_name_for_inspect,
            field: normalized[:field].to_s,
            limit: normalized[:limit],
            missing_values: normalized[:missing_values]
          }
          SearchEngine::Instrumentation.instrument('search_engine.relation.group_by_updated', payload) {}
        rescue StandardError
          # swallow observability errors
        end
      end

      rel
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
      normalized = normalize_select_input(fields)

      base_empty = Array(normalized[:base]).empty?
      nested_empty = normalized[:nested_order].all? { |a| Array(normalized[:nested][a]).empty? }
      raise ArgumentError, 'reselect: provide at least one non-blank field' if base_empty && nested_empty

      spawn do |s|
        s[:select] = normalized[:base]
        s[:select_nested] = normalized[:nested]
        s[:select_nested_order] = normalized[:nested_order]
      end
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

      nodes = SearchEngine::DSL::Parser.parse(input, klass: @klass, args: args, joins: joins_list)
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
            s[:select_nested] = {}
            s[:select_nested_order] = []
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

    # Compile immutable relation state and options into Typesense body params.
    # The compiler is pure/deterministic and omits URL-level cache knobs.
    #
    # Key insertion order: q, query_by, filter_by, sort_by, include_fields, page, per_page, infix.
    # Empty/nil values are omitted.
    #
    # May emit grouping keys when present:
    # - group_by [String]
    # - group_limit [Integer]
    # - group_missing_values [Boolean, only when true]
    # Validation: field present (Symbol/String), limit positive Integer if provided, missing_values Boolean.
    #
    # @return [Hash] typesense body params suitable for Client#search
    # @example
    #   rel.to_typesense_params
    #   # => { q: "*", query_by: "name,description", filter_by: "brand_id:=[1,2] && active:=true", page: 2, per_page: 20 }
    def to_typesense_params # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/MethodLength
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
      compile_started_ms = SearchEngine::Instrumentation.monotonic_ms if defined?(SearchEngine::Instrumentation)
      filter_str = compiled_filter_by(ast_nodes)
      params[:filter_by] = filter_str if filter_str

      orders = Array(@state[:orders])
      sort_str = compiled_sort_by(orders)
      params[:sort_by] = sort_str if sort_str

      # Field selection (nested first, then base)
      include_str = compile_include_fields_string
      params[:include_fields] = include_str unless include_str.to_s.strip.empty?

      # Pagination
      pagination = compute_pagination
      params[:page] = pagination[:page] if pagination.key?(:page)
      params[:per_page] = pagination[:per_page] if pagination.key?(:per_page)

      # Grouping
      grouping = @state[:grouping]
      if grouping
        field = grouping[:field]
        limit = grouping[:limit]
        missing_values = grouping[:missing_values]

        field_valid = field.is_a?(Symbol) || field.is_a?(String)
        limit_valid = limit.nil? || (limit.is_a?(Integer) && limit.positive?)
        missing_values_bool = [true, false].include?(missing_values)

        raise SearchEngine::Errors::InvalidGroup, 'InvalidGroup: field must be a Symbol or String' unless field_valid

        unless limit_valid
          raise SearchEngine::Errors::InvalidGroup,
                "InvalidGroup: limit must be a positive integer (got #{limit.inspect})"
        end
        unless missing_values_bool
          raise SearchEngine::Errors::InvalidGroup,
                "InvalidGroup: missing_values must be boolean (got #{missing_values.inspect})"
        end

        # Defensive unknown field and unsupported path checks
        field_str = field.to_s
        if field_str.start_with?('$') || field_str.include?('.')
          raise SearchEngine::Errors::UnsupportedGroupField,
                %(UnsupportedGroupField: grouping supports base fields only (got #{field_str.inspect}))
        end
        attrs = safe_attributes_map
        unless attrs.nil? || attrs.empty? || attrs.key?(field.to_sym)
          msg = build_invalid_group_unknown_field_message(field.to_sym)
          raise SearchEngine::Errors::InvalidGroup, msg
        end

        # Guardrail warnings (non-fatal)
        begin
          if grouping_warnings_enabled?(cfg)
            # 1) order vs group ordering
            unless orders.empty?
              cfg.logger&.warn('[search_engine] order affects hits, not group ordering.')
              cfg.logger&.warn('[search_engine] Groups follow engine ranking.')
              cfg.logger&.warn('[search_engine] Tip: Use filters to control the first hit per group.')
            end

            # 2) grouping field omitted from include_fields (only when include_fields present)
            base_selected = Array(@state[:select]).map(&:to_s)
            if !base_selected.empty? && !base_selected.include?(field_str)
              cfg.logger&.warn(%([search_engine] Grouping by `#{field_str}` without selecting it may be confusing.))
              cfg.logger&.warn('[search_engine] Consider including it in fields or read it from `Group#key`.')
            end

            # 3) missing_values: true combined with filters excluding nulls for the grouping field
            if missing_values && excludes_nulls_for_field?(ast_nodes, field_str)
              cfg.logger&.warn(
                %([search_engine] missing_values: true + filters excluding `null` for `#{field_str}` )
              )
              cfg.logger&.warn('[search_engine] may produce fewer missing groups than expected.')
            end
          end
        rescue StandardError
          # Do not fail search on logging issues
        end

        # Compile-time grouping timing start
        grouping_started_ms = SearchEngine::Instrumentation.monotonic_ms if defined?(SearchEngine::Instrumentation)

        params[:group_by] = field_str
        params[:group_limit] = limit if limit
        params[:group_missing_values] = true if missing_values

        # Emit compile-time grouping event with minimal payload
        if defined?(SearchEngine::Instrumentation)
          begin
            g_payload = {
              collection: klass_name_for_inspect,
              field: field_str,
              limit: limit,
              missing_values: missing_values,
              duration_ms: (SearchEngine::Instrumentation.monotonic_ms - grouping_started_ms if grouping_started_ms)
            }
            SearchEngine::Instrumentation.instrument('search_engine.grouping.compile', g_payload)
          rescue StandardError
            # swallow observability errors
          end
        end
      end

      # Keep infix last for stability; include when configured or overridden
      infix_val = option_value(opts, :infix) || cfg.default_infix
      params[:infix] = infix_val if infix_val

      # Internal join context (for downstream components; may be stripped before HTTP)
      join_ctx = build_join_context(ast_nodes: ast_nodes, orders: orders)
      params[:_join] = join_ctx unless join_ctx.nil? || join_ctx.empty?

      # Emit compile-time JOINs event summarizing usage (no raw strings)
      if defined?(SearchEngine::Instrumentation)
        begin
          assocs = Array(join_ctx[:assocs]).map(&:to_s)
          used = join_ctx[:referenced_in] || {}
          used_in = {}
          %i[include filter sort].each do |k|
            arr = Array(used[k]).map(&:to_s)
            used_in[k] = arr unless arr.empty?
          end

          payload = {
            collection: klass_name_for_inspect,
            join_count: assocs.size,
            assocs: (assocs unless assocs.empty?),
            used_in: (used_in unless used_in.empty?),
            include_len: (include_str.to_s.length unless include_str.to_s.strip.empty?),
            filter_len: (filter_str.to_s.length unless filter_str.to_s.strip.empty?),
            sort_len:   (sort_str.to_s.length unless sort_str.to_s.strip.empty?),
            duration_ms: (SearchEngine::Instrumentation.monotonic_ms - compile_started_ms if compile_started_ms),
            has_joins: !assocs.empty?
          }
          SearchEngine::Instrumentation.instrument('search_engine.joins.compile', payload)
        rescue StandardError
          # swallow observability errors
        end
      end

      params
    end

    # Convenience alias to compiled body params.
    alias to_h to_typesense_params

    # Explain the current relation without performing any network calls.
    #
    # Returns a concise, multi-line String summarizing chainers and compiled
    # parameters. When `to: :stdout` is provided, also prints the summary.
    #
    # @param to [Symbol, nil] when `:stdout`, prints to STDOUT in addition to returning
    # @return [String]
    # @example
    #   rel.explain
    #   #=> "SearchEngine::Product Relation\n  where: active:=true AND brand_id IN [1,2]\n  order: updated_at:desc\n  select: id,name\n  page/per: 2/20"
    def explain(to: nil)
      params = to_typesense_params

      lines = []
      header = "#{klass_name_for_inspect} Relation"
      lines << header

      if params[:filter_by] && !params[:filter_by].to_s.strip.empty?
        where_str = friendly_where(params[:filter_by].to_s)
        lines << "  where: #{where_str}"
      end

      lines << "  order: #{params[:sort_by]}" if params[:sort_by] && !params[:sort_by].to_s.strip.empty?

      if (g = @state[:grouping])
        gparts = ["group_by=#{g[:field]}"]
        gparts << "limit=#{g[:limit]}" if g[:limit]
        gparts << 'missing_values=true' if g[:missing_values]
        lines << "  group: #{gparts.join(' ')}"
      end

      if params[:include_fields] && !params[:include_fields].to_s.strip.empty?
        lines << "  select: #{params[:include_fields]}"
      end

      add_pagination_line!(lines, params)

      out = lines.join("\n")
      puts(out) if to == :stdout
      out
    end

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

    # Join association names to include in server-side join compilation.
    #
    # Validates each provided association against the model's `joins_config` and
    # appends the normalized names to the relation state in order. The relation
    # is immutable; a new instance is returned with copy-on-write semantics.
    #
    # @param assocs [Array<#to_sym,#to_s>] one or more association names
    # @return [SearchEngine::Relation]
    # @raise [SearchEngine::Errors::UnknownJoin] when an association is not declared
    # @raise [ArgumentError] when inputs are not Symbols/Strings
    # @see docs/joins.md
    # @example
    #   SearchEngine::Book
    #     .joins(:authors)
    #     .where(orders: { total_price: 12.34 })
    def joins(*assocs)
      names = normalize_joins(assocs)
      return self if names.empty?

      # Validate all first for better error UX
      names.each { |name| SearchEngine::Joins::Guard.ensure_config_complete!(@klass, name) }

      spawn do |s|
        existing = Array(s[:joins])
        s[:joins] = existing + names
      end
    end

    # Read-only list of join association names accumulated on this relation.
    # @return [Array<Symbol>] a frozen array
    def joins_list
      list = Array(@state[:joins])
      list.frozen? ? list : list.dup.freeze
    end

    # Read-only grouping state for debugging/explain.
    # @return [Hash, nil] frozen hash `{ field: Symbol, limit: Integer/nil, missing_values: Boolean }` or nil
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
      when String
        value.inspect
      when Array
        "[#{value.map { |v| format_value_for_inspect(v) }.join(', ')}]"
      else
        value.inspect
      end
    end

    def friendly_where(filter_by)
      s = filter_by.to_s
      return s if s.empty?

      # Replace tokens for readability
      s = s.gsub(' && ', ' AND ')
      s = s.gsub(' || ', ' OR ')
      s = s.gsub(':=[', ' IN [')
      s.gsub(':!=[', ' NOT IN [')
    end

    def normalize_initial_state(state)
      return {} if state.nil? || state.empty?
      raise ArgumentError, 'state must be a Hash' unless state.is_a?(Hash)

      normalized = {}
      state.each { |key, value| apply_initial_state_key!(normalized, key, value) }
      normalized
    end

    def apply_initial_state_key!(normalized, key, value) # rubocop:disable Metrics/AbcSize
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
      when :select_nested
        normalized[:select_nested] = (value || {})
      when :select_nested_order
        normalized[:select_nested_order] = Array(value).flatten.compact.map(&:to_sym)
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
      end
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
          i = normalize_where_process_string!(fragments, entry, list, i)
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

    def normalize_where_process_string!(fragments, entry, list, i)
      if entry.match?(/(?<!\\)\?/) # has unescaped placeholders
        tail = list[(i + 1)..] || []
        needed = SearchEngine::Filters::Sanitizer.count_placeholders(entry)
        args_for_template = tail.first(needed)
        if args_for_template.length != needed
          raise ArgumentError, "expected #{needed} args for #{needed} placeholders, got #{args_for_template.length}"
        end

        fragments << SearchEngine::Filters::Sanitizer.apply_placeholders(entry, args_for_template)
        i + 1 + needed
      else
        fragments << entry.to_s
        i + 1
      end
    end

    # Parse and normalize order input into an array of "field:dir" strings.
    def normalize_order(value) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity
      return [] if value.nil?

      case value
      when Hash
        value.flat_map do |k, dir|
          if dir.is_a?(Hash)
            # Nested assoc: { assoc => { field => :asc|:desc } }
            assoc = k.to_sym
            # Validate assoc exists and join applied
            @klass.join_for(assoc)
            SearchEngine::Joins::Guard.ensure_join_applied!(joins_list, assoc, context: 'sorting')

            dir.flat_map do |field_name, d|
              field = field_name.to_s.strip
              raise ArgumentError, 'order: field name must be non-empty' if field.empty?

              begin
                cfg = @klass.join_for(assoc)
                SearchEngine::Joins::Guard.validate_joined_field!(cfg, field)
              rescue StandardError
                # best-effort only
              end

              direction = d.to_s.strip.downcase
              unless %w[asc desc].include?(direction)
                raise ArgumentError,
                      "order: direction must be :asc or :desc (got #{d.inspect} for field #{field_name.inspect})"
              end

              "$#{assoc}.#{field}:#{direction}"
            end
          else
            field = k.to_s.strip
            raise ArgumentError, 'order: field name must be non-empty' if field.empty?

            direction = dir.to_s.strip.downcase
            unless %w[asc desc].include?(direction)
              raise ArgumentError, "order: direction must be :asc or :desc (got #{dir.inspect} for field #{k.inspect})"
            end

            "#{field}:#{direction}"
          end
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

    # Base-only normalization used internally and for legacy callers.
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

    # Extended normalization supporting nested association selections.
    # Returns a Hash with keys: :base (Array<String>), :nested (Hash<Symbol,Array<String>>), :nested_order (Array<Symbol>).
    def normalize_select_input(fields) # rubocop:disable Metrics/AbcSize
      list = Array(fields).flatten.compact
      return { base: [], nested: {}, nested_order: [] } if list.empty?

      base = []
      nested = {}
      nested_order = []

      add_base = ->(val) { base.concat(normalize_select([val])) }

      add_nested = lambda do |assoc, values|
        key = assoc.to_sym
        @klass.join_for(key)
        # Enforce that the relation has applied the join before selecting nested fields
        SearchEngine::Joins::Guard.ensure_join_applied!(joins_list, key, context: 'selecting fields')

        items = case values
                when Array then values
                when nil then []
                else [values]
                end
        names = items.flatten.compact.map(&:to_s).map(&:strip).reject(&:empty?)
        return if names.empty?

        # Optional: validate joined field names if target collection model is available
        begin
          cfg = @klass.join_for(key)
          names.each do |fname|
            SearchEngine::Joins::Guard.validate_joined_field!(cfg, fname)
          end
        rescue StandardError
          # Best-effort only; skip strict validation if registry or attributes unavailable
        end

        existing = Array(nested[key])
        merged = (existing + names).each_with_object([]) { |n, acc| acc << n unless acc.include?(n) }
        nested[key] = merged
        nested_order << key unless nested_order.include?(key)
      end

      i = 0
      while i < list.length
        entry = list[i]
        case entry
        when Hash
          entry.each { |k, v| add_nested.call(k, v) }
          i += 1
        when Symbol, String
          add_base.call(entry)
          i += 1
        when Array
          inner = Array(entry).flatten.compact
          inner.each { |el| list << el }
          i += 1
        else
          raise ArgumentError, "select/include_fields: unsupported input #{entry.class}"
        end
      end

      { base: base.uniq, nested: nested, nested_order: nested_order }
    end

    def normalize_grouping(value)
      return nil if value.nil? || value.empty?
      raise ArgumentError, 'grouping: expected a Hash' unless value.is_a?(Hash)

      field = value[:field]
      limit = value[:limit]
      missing_values = value[:missing_values]

      unless field.is_a?(Symbol) || field.is_a?(String)
        raise SearchEngine::Errors::InvalidGroup,
              'InvalidGroup: field must be a Symbol or String'
      end

      # Disallow joined/path fields like "$assoc.field"
      field_str = field.to_s
      if field_str.start_with?('$') || field_str.include?('.')
        raise SearchEngine::Errors::UnsupportedGroupField,
              %(UnsupportedGroupField: grouping supports base fields only (got #{field_str.inspect}))
      end

      # Validate existence against declared attributes when available
      attrs = safe_attributes_map
      unless attrs.nil? || attrs.empty?
        sym = field.to_sym
        unless attrs.key?(sym)
          msg = build_invalid_group_unknown_field_message(sym)
          raise SearchEngine::Errors::InvalidGroup, msg
        end
      end

      # Validate limit positivity when provided
      if !limit.nil? && !(limit.is_a?(Integer) && limit >= 1)
        got = limit.nil? ? 'nil' : limit.inspect
        raise SearchEngine::Errors::InvalidGroup,
              "InvalidGroup: limit must be a positive integer (got #{got})"
      end

      # Validate missing_values strict boolean
      unless [true, false].include?(missing_values)
        raise SearchEngine::Errors::InvalidGroup,
              "InvalidGroup: missing_values must be boolean (got #{missing_values.inspect})"
      end

      { field: field.to_sym, limit: limit, missing_values: missing_values }
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

    def coerce_boolean_strict(value, name)
      case value
      when true, false
        value
      when String
        s = value.to_s.strip.downcase
        return true  if %w[1 true yes on t].include?(s)

        return false if %w[0 false no off f].include?(s)

        raise ArgumentError, "#{name} must be a boolean"
      when Integer
        return true  if value == 1

        return false if value.zero?

        raise ArgumentError, "#{name} must be a boolean"
      else
        raise ArgumentError, "#{name} must be a boolean"
      end
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

      begin
        cfg = SearchEngine.config
        return unless cfg.respond_to?(:strict_fields) ? cfg.strict_fields : true
      rescue StandardError
        # Intentionally ignore config access errors and fall back to strict behavior
      end

      klass_name = klass_name_for_inspect
      known_list = known.map(&:to_s).sort.join(', ')
      unknown_name = unknown.first.inspect
      raise ArgumentError, "Unknown attribute #{unknown_name} for #{klass_name}. Known: #{known_list}"
    end

    # Build include_fields string with nested association segments first, then base fields.
    def compile_include_fields_string
      nested_order = Array(@state[:select_nested_order])
      nested_map = @state[:select_nested] || {}

      segments = []
      nested_order.each do |assoc|
        fields = Array(nested_map[assoc]).map(&:to_s).reject(&:empty?)
        next if fields.empty?

        segments << "$#{assoc}(#{fields.join(',')})"
      end

      base = Array(@state[:select])
      segments.concat(base) unless base.empty?

      segments.join(',')
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

    def add_pagination_line!(lines, params)
      page = params[:page]
      per = params[:per_page]
      return unless page || per

      if page && per
        lines << "  page/per: #{page}/#{per}"
      elsif page
        lines << "  page/per: #{page}/"
      elsif per
        lines << "  page/per: /#{per}"
      end
    end

    # Normalize and validate join names, preserving order and duplicates.
    def normalize_joins(values)
      list = Array(values).flatten.compact
      return [] if list.empty?

      names = list.map do |v|
        case v
        when Symbol, String
          v.to_sym
        else
          raise ArgumentError, "joins: expected symbols/strings (got #{v.class})"
        end
      end

      # Validate against declared joins; rely on join_for to raise with suggestions
      names.each { |name| @klass.join_for(name) }
      names
    end

    # Compile filter_by string from AST nodes or legacy fragments.
    # @param ast_nodes [Array<SearchEngine::AST::Node>]
    # @return [String, nil]
    def compiled_filter_by(ast_nodes)
      unless ast_nodes.empty?
        compiled = SearchEngine::Compiler.compile(ast_nodes, klass: @klass)
        return nil if compiled.to_s.empty?

        return compiled
      end

      fragments = Array(@state[:filters])
      return nil if fragments.empty?

      fragments.join(' && ')
    end

    # Compile sort_by from normalized order entries.
    # @param orders [Array<String>]
    # @return [String, nil]
    def compiled_sort_by(orders)
      list = Array(orders)
      return nil if list.empty?

      list.join(',')
    end

    # Build a JSON-serializable join context for Typesense.
    # Internal, documented shape used by downstream layers for diagnostics and planning:
    #   {
    #     assocs: [:authors, ...],
    #     fields_by_assoc: { authors: ["first_name", ...] },
    #     referenced_in: { include: [:authors], filter: [:authors], sort: [:authors] }
    #   }
    # @param ast_nodes [Array<SearchEngine::AST::Node>]
    # @param orders [Array<String>]
    # @return [Hash]
    def build_join_context(ast_nodes:, orders:)
      applied = Array(@state[:joins])
      return {} if applied.empty?

      # Dedupe while preserving first occurrence order
      assocs = []
      applied.each { |a| assocs << a unless assocs.include?(a) }

      nested_map = @state[:select_nested] || {}
      nested_order = Array(@state[:select_nested_order])

      fields_by_assoc = {}
      assocs.each do |assoc|
        fields = Array(nested_map[assoc]).map(&:to_s).reject(&:empty?)
        fields_by_assoc[assoc] = fields unless fields.empty?
      end

      include_refs = nested_order.select { |a| Array(nested_map[a]).any? }
      filter_refs = extract_assocs_from_ast(ast_nodes)
      sort_refs = extract_assocs_from_orders(orders)

      referenced_in = {}
      referenced_in[:include] = include_refs unless include_refs.empty?
      referenced_in[:filter] = filter_refs unless filter_refs.empty?
      referenced_in[:sort] = sort_refs unless sort_refs.empty?

      out = {}
      out[:assocs] = assocs unless assocs.empty?
      out[:fields_by_assoc] = fields_by_assoc unless fields_by_assoc.empty?
      out[:referenced_in] = referenced_in unless referenced_in.empty?
      out
    end

    # Walk AST nodes and collect association names used via "$assoc.field" LHS.
    # @param nodes [Array<SearchEngine::AST::Node>]
    # @return [Array<Symbol>] unique assoc names in first-mention order
    def extract_assocs_from_ast(nodes)
      list = Array(nodes).flatten.compact
      return [] if list.empty?

      seen = []
      walker = lambda do |node|
        return unless node.is_a?(SearchEngine::AST::Node)

        if node.respond_to?(:field)
          field = node.field.to_s
          if field.start_with?('$')
            m = field.match(/^\$(\w+)\./)
            if m
              name = m[1].to_sym
              seen << name unless seen.include?(name)
            end
          end
        end

        Array(node.children).each { |child| walker.call(child) }
      end

      list.each { |n| walker.call(n) }
      seen
    end

    # Parse order strings and collect assoc names used via "$assoc.field:dir".
    # @param orders [Array<String>]
    # @return [Array<Symbol>] unique assoc names in first-mention order
    def extract_assocs_from_orders(orders)
      list = Array(orders).flatten.compact
      return [] if list.empty?

      seen = []
      list.each do |entry|
        field, _dir = entry.to_s.split(':', 2)
        next unless field&.start_with?('$')

        m = field.match(/^\$(\w+)\./)
        next unless m

        name = m[1].to_sym
        seen << name unless seen.include?(name)
      end
      seen
    end

    # Build an actionable InvalidGroup message for unknown field with suggestions.
    def build_invalid_group_unknown_field_message(field_sym)
      klass_name = klass_name_for_inspect
      known = safe_attributes_map.keys.map(&:to_sym)
      suggestions = suggest_fields(field_sym, known)
      suggestion_str =
        if suggestions.empty?
          ''
        elsif suggestions.length == 1
          " (did you mean :#{suggestions.first}?)"
        else
          last = suggestions.last
          others = suggestions[0..-2].map { |s| ":#{s}" }.join(', ')
          " (did you mean #{others}, or :#{last}?)"
        end
      "InvalidGroup: unknown field :#{field_sym} for grouping on #{klass_name}#{suggestion_str}"
    end

    # Lightweight suggestion helper using Levenshtein; returns up to 3 candidates within distance <= 2.
    def suggest_fields(field_sym, known_syms)
      return [] if known_syms.nil? || known_syms.empty?

      input = field_sym.to_s
      candidates = known_syms.map(&:to_s)
      begin
        require 'did_you_mean'
        require 'did_you_mean/levenshtein'
      rescue StandardError
        return []
      end

      distances = candidates.each_with_object({}) do |cand, acc|
        acc[cand] = DidYouMean::Levenshtein.distance(input, cand)
      end
      # Select up to 3 with minimal distance under threshold
      sorted = distances.sort_by { |(_cand, d)| d }
      threshold = 2
      sorted.take(3).select { |(_cand, d)| d <= threshold }.map { |cand, _d| cand.to_sym }
    end

    def grouping_warnings_enabled?(cfg)
      cfg&.grouping&.warn_on_ambiguous
    end

    def excludes_nulls_for_field?(ast_nodes, field_str)
      field = field_str.to_s
      Array(ast_nodes).flatten.any? do |node|
        case node
        when SearchEngine::AST::NotEq
          node.field.to_s == field && node.value.nil?
        when SearchEngine::AST::NotIn
          node.field.to_s == field && Array(node.values).include?(nil)
        else
          false
        end
      end
    end
  end
end
