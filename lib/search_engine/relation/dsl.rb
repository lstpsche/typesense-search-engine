# frozen_string_literal: true

module SearchEngine
  class Relation
    # User-facing chainers and input normalizers.
    # Chainers MUST be copy-on-write and return new Relation instances.
    module DSL
      # Add filters to the relation.
      # @param args [Array<Object>] filter arguments
      # @return [SearchEngine::Relation]
      def where(*args)
        ast_nodes = SearchEngine::DSL::Parser.parse_list(args, klass: @klass, joins: joins_list)
        fragments = normalize_where(args)
        spawn do |s|
          s[:ast] = Array(s[:ast]) + Array(ast_nodes)
          s[:filters] = Array(s[:filters]) + fragments
        end
      end

      # Append ordering expressions. Accepts Hash or String forms.
      # @param value [Hash, String]
      # @return [SearchEngine::Relation]
      def order(value)
        additions = normalize_order(value)
        spawn do |s|
          existing = Array(s[:orders])
          s[:orders] = dedupe_orders_last_wins(existing + additions)
        end
      end

      # Select a subset of fields for Typesense `include_fields`.
      # @param fields [Array<Symbol,String,Hash,Array>]
      # @return [SearchEngine::Relation]
      def select(*fields)
        normalized = normalize_select_input(fields)
        spawn do |s|
          existing_base = Array(s[:select])
          merged_base = (existing_base + normalized[:base]).each_with_object([]) do |f, acc|
            acc << f unless acc.include?(f)
          end
          s[:select] = merged_base

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
      # @param fields [Array]
      # @return [SearchEngine::Relation]
      def include_fields(*fields)
        select(*fields)
      end

      # Apply a server-side preset with a specified merge strategy.
      # @param name [#to_s, #to_sym]
      # @param mode [Symbol]
      # @return [SearchEngine::Relation]
      def preset(name, mode: :merge)
        raise ArgumentError, 'preset requires a name' if name.nil?

        token = name.to_s.strip
        raise ArgumentError, 'preset name must be non-empty' if token.empty?

        sym_mode = mode.to_sym
        unless %i[merge only lock].include?(sym_mode)
          raise ArgumentError, "preset mode must be one of :merge, :only, :lock (got #{mode.inspect})"
        end

        cfg = SearchEngine.config.presets
        effective = if cfg.enabled && cfg.namespace
                      +"#{cfg.namespace}_#{token}"
                    else
                      token.dup
                    end

        spawn do |s|
          s[:preset_name] = effective
          s[:preset_mode] = sym_mode
        end
      end

      # Fine-grained ranking & typo tuning.
      # @return [SearchEngine::Relation]
      def ranking(num_typos: nil, drop_tokens_threshold: nil, prioritize_exact_match: nil, query_by_weights: nil)
        normalized = normalize_ranking_input(
          num_typos: num_typos,
          drop_tokens_threshold: drop_tokens_threshold,
          prioritize_exact_match: prioritize_exact_match,
          query_by_weights: query_by_weights
        )

        spawn do |s|
          current = s[:ranking] || {}
          merged = current.dup
          %i[num_typos drop_tokens_threshold prioritize_exact_match].each do |k|
            merged[k] = normalized[k] unless normalized[k].nil?
          end
          if normalized.key?(:query_by_weights)
            existing = current[:query_by_weights] || {}
            merged[:query_by_weights] = existing.merge(normalized[:query_by_weights])
          end
          s[:ranking] = merged
        end
      end

      # Control Typesense infix/prefix matching per relation via a simple enum.
      # @return [SearchEngine::Relation]
      def prefix(mode)
        sym = mode.to_s.strip.downcase.to_sym
        valid = {
          disabled: 'off',
          fallback: 'fallback',
          always: 'always'
        }
        unless valid.key?(sym)
          raise SearchEngine::Errors::InvalidOption.new(
            "InvalidOption: unknown prefix mode #{mode.inspect}",
            hint: 'Use :disabled, :fallback, or :always',
            doc: 'docs/ranking.md#prefix',
            details: { provided: mode, allowed: valid.keys }
          )
        end

        token = valid[sym]
        spawn do |s|
          opts = (s[:options] || {}).dup
          opts[:infix] = token
          s[:options] = opts
        end
      end

      # Exclude a subset of fields from the final selection.
      # @param fields [Array<Symbol,String,Hash,Array>]
      # @return [SearchEngine::Relation]
      def exclude(*fields)
        normalized = normalize_select_input(fields, context: 'excluding fields')
        spawn do |s|
          existing_base = Array(s[:exclude])
          merged_base = (existing_base + normalized[:base]).each_with_object([]) do |f, acc|
            acc << f unless acc.include?(f)
          end
          s[:exclude] = merged_base

          existing_nested = s[:exclude_nested] || {}
          existing_order = Array(s[:exclude_nested_order])

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

          s[:exclude_nested] = existing_nested
          s[:exclude_nested_order] = existing_order
        end
      end

      # Pin hits to the top of results by ID.
      # @param ids [Array<#to_s>]
      # @return [SearchEngine::Relation]
      def pin(*ids)
        additions = normalize_curation_ids(ids)
        return self if additions.empty?

        spawn do |s|
          cur = s[:curation] || { pinned: [], hidden: [], override_tags: [], filter_curated_hits: nil }
          cur[:pinned] = (Array(cur[:pinned]) + additions).each_with_object([]) do |t, acc|
            acc << t unless acc.include?(t)
          end
          s[:curation] = cur
        end
      end

      # Hide hits by ID.
      # @param ids [Array<#to_s>]
      # @return [SearchEngine::Relation]
      def hide(*ids)
        additions = normalize_curation_ids(ids)
        return self if additions.empty?

        spawn do |s|
          cur = s[:curation] || { pinned: [], hidden: [], override_tags: [], filter_curated_hits: nil }
          cur[:hidden] = (Array(cur[:hidden]) + additions).each_with_object([]) do |t, acc|
            acc << t unless acc.include?(t)
          end
          s[:curation] = cur
        end
      end

      # Set multiple curation knobs in one call.
      # @return [SearchEngine::Relation]
      def curate(pin: nil, hide: nil, override_tags: nil, filter_curated_hits: :__unset__)
        spawn do |s|
          cur = s[:curation] || { pinned: [], hidden: [], override_tags: [], filter_curated_hits: nil }

          unless pin.nil?
            list = normalize_curation_ids(pin)
            cur[:pinned] = list.each_with_object([]) { |t, acc| acc << t unless acc.include?(t) }
          end
          unless hide.nil?
            list = normalize_curation_ids(hide)
            cur[:hidden] = list.each_with_object([]) { |t, acc| acc << t unless acc.include?(t) }
          end
          cur[:override_tags] = normalize_curation_tags(override_tags) unless override_tags.nil?
          if filter_curated_hits != :__unset__
            cur[:filter_curated_hits] =
              filter_curated_hits.nil? ? nil : coerce_boolean_strict(filter_curated_hits, :filter_curated_hits)
          end

          s[:curation] = cur
        end
      end

      # Clear all curation state from the relation.
      # @return [SearchEngine::Relation]
      def clear_curation
        spawn do |s|
          s[:curation] = nil
        end
      end

      # Group results by a single field with optional limit and missing values policy.
      # @return [SearchEngine::Relation]
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
          end
        end

        rel
      end

      # Replace the selected fields list (Typesense `include_fields`).
      # @param fields [Array<#to_sym,#to_s>]
      # @return [SearchEngine::Relation]
      def reselect(*fields)
        normalized = normalize_select_input(fields)

        base_empty = Array(normalized[:base]).empty?
        nested_empty = normalized[:nested_order].all? { |a| Array(normalized[:nested][a]).empty? }
        raise ArgumentError, 'reselect: provide at least one non-blank field' if base_empty && nested_empty

        spawn do |s|
          s[:select] = normalized[:base]
          s[:select_nested] = normalized[:nested]
          s[:select_nested_order] = normalized[:nested_order]
          s[:exclude] = []
          s[:exclude_nested] = {}
          s[:exclude_nested_order] = []
        end
      end

      # Replace all predicates with a new where input.
      # @param input [Hash, String, Array, Symbol]
      # @param args [Array<Object>]
      # @return [SearchEngine::Relation]
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
      # @return [SearchEngine::Relation]
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
              s[:exclude] = []
              s[:exclude_nested] = {}
              s[:exclude_nested_order] = []
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
      # @return [SearchEngine::Relation]
      def limit(n)
        value = coerce_integer_min(n, :limit, 1)
        spawn { |s| s[:limit] = value }
      end

      # Set the offset of results.
      # @return [SearchEngine::Relation]
      def offset(n)
        value = coerce_integer_min(n, :offset, 0)
        spawn { |s| s[:offset] = value }
      end

      # Set page number.
      # @return [SearchEngine::Relation]
      def page(n)
        value = coerce_integer_min(n, :page, 1)
        spawn { |s| s[:page] = value }
      end

      # Set per-page size.
      # @return [SearchEngine::Relation]
      def per_page(n)
        value = coerce_integer_min(n, :per, 1)
        spawn { |s| s[:per_page] = value }
      end

      # Convenience alias for per-page size.
      # @return [SearchEngine::Relation]
      def per(n)
        per_page(n)
      end

      # Shallow-merge options into the relation.
      # @param opts [Hash]
      # @return [SearchEngine::Relation]
      def options(opts = {})
        raise ArgumentError, 'options must be a Hash' unless opts.is_a?(Hash)

        spawn do |s|
          s[:options] = (s[:options] || {}).merge(opts)
        end
      end

      # Join association names to include in server-side join compilation.
      # @param assocs [Array<#to_sym,#to_s>]
      # @return [SearchEngine::Relation]
      def joins(*assocs)
        names = normalize_joins(assocs)
        return self if names.empty?

        names.each { |name| SearchEngine::Joins::Guard.ensure_config_complete!(@klass, name) }

        spawn do |s|
          existing = Array(s[:joins])
          s[:joins] = existing + names
        end
      end

      # Control usage of synonyms at query time.
      # @return [SearchEngine::Relation]
      def use_synonyms(value)
        v = value.nil? ? nil : coerce_boolean_strict(value, :use_synonyms)
        spawn do |s|
          s[:use_synonyms] = v
        end
      end

      # Control usage of stopwords at query time.
      # @return [SearchEngine::Relation]
      def use_stopwords(value)
        v = value.nil? ? nil : coerce_boolean_strict(value, :use_stopwords)
        spawn do |s|
          s[:use_stopwords] = v
        end
      end

      # Faceting DSL
      # ---------------
      def facet_by(field, max_values: nil, sort: nil, stats: nil)
        name = field.to_s.strip
        raise SearchEngine::Errors::InvalidParams, 'facet_by: field name must be non-empty' if name.empty?

        if name.start_with?('$') || name.include?('.')
          raise SearchEngine::Errors::InvalidParams.new(
            %(facet_by: supports base fields only (got #{name.inspect})),
            doc: 'docs/faceting.md#supported-options',
            details: { field: name }
          )
        end

        attrs = safe_attributes_map
        unless attrs.nil? || attrs.empty? || attrs.key?(name.to_sym)
          suggestions = suggest_fields(name.to_sym, attrs.keys.map(&:to_sym))
          suggest = if suggestions.empty?
                      ''
                    elsif suggestions.length == 1
                      " (did you mean :#{suggestions.first}?)"
                    else
                      last = suggestions.last
                      others = suggestions[0..-2].map { |s| ":#{s}" }.join(', ')
                      " (did you mean #{others}, or :#{last}?)"
                    end
          raise SearchEngine::Errors::UnknownField,
                "UnknownField: unknown field #{name.inspect} for #{klass_name_for_inspect}#{suggest}"
        end

        unless sort.nil?
          raise SearchEngine::Errors::InvalidParams.new(
            "facet_by: option :sort is not supported by Typesense facets (got #{sort.inspect})",
            hint: 'Supported: default count-desc only at present.',
            doc: 'docs/faceting.md#supported-options',
            details: { sort: sort }
          )
        end

        unless stats.nil?
          raise SearchEngine::Errors::InvalidParams.new(
            'facet_by: option :stats is not supported at present',
            doc: 'docs/faceting.md#supported-options',
            details: { stats: stats }
          )
        end

        cap = nil
        unless max_values.nil?
          begin
            cap = Integer(max_values)
          rescue ArgumentError, TypeError
            raise SearchEngine::Errors::InvalidParams, 'facet_by: max_values must be an Integer or nil'
          end
          raise SearchEngine::Errors::InvalidParams, 'facet_by: max_values must be >= 1' if cap < 1
        end

        spawn do |s|
          fields = Array(s[:facet_fields])
          s[:facet_fields] = fields.include?(name) ? fields : (fields + [name])

          caps = Array(s[:facet_max_values])
          s[:facet_max_values] = cap.nil? ? caps : (caps + [cap])
        end
      end

      def facet_query(field, expression, label: nil)
        name = field.to_s.strip
        raise SearchEngine::Errors::InvalidParams, 'facet_query: field name must be non-empty' if name.empty?

        if name.start_with?('$') || name.include?('.')
          raise SearchEngine::Errors::InvalidParams.new(
            %(facet_query: supports base fields only (got #{name.inspect})),
            doc: 'docs/faceting.md#supported-options',
            details: { field: name }
          )
        end

        attrs = safe_attributes_map
        unless attrs.nil? || attrs.empty? || attrs.key?(name.to_sym)
          suggestions = suggest_fields(name.to_sym, attrs.keys.map(&:to_sym))
          suggest = if suggestions.empty?
                      ''
                    elsif suggestions.length == 1
                      " (did you mean :#{suggestions.first}?)"
                    else
                      last = suggestions.last
                      others = suggestions[0..-2].map { |s| ":#{s}" }.join(', ')
                      " (did you mean #{others}, or :#{last}?)"
                    end
          raise SearchEngine::Errors::UnknownField,
                "UnknownField: unknown field #{name.inspect} for #{klass_name_for_inspect}#{suggest}"
        end

        expr = expression.to_s.strip
        raise SearchEngine::Errors::InvalidParams, 'facet_query: expression must be a non-empty String' if expr.empty?

        if expr.include?('[') ^ expr.include?(']')
          raise SearchEngine::Errors::InvalidParams.new(
            %(facet_query: invalid range syntax #{expr.inspect} (unbalanced brackets)),
            hint: 'Use shapes like "[0..9]", "[10..19]"',
            doc: 'docs/faceting.md#facet-query-expressions',
            details: { expr: expr }
          )
        end

        label_str = label&.to_s&.strip

        spawn do |s|
          queries = Array(s[:facet_queries])
          rec = { field: name, expr: expr }
          rec[:label] = label_str unless label_str.nil? || label_str.empty?
          exists = queries.any? { |q| q[:field] == rec[:field] && q[:expr] == rec[:expr] && q[:label] == rec[:label] }
          s[:facet_queries] = exists ? queries : (queries + [rec])
        end
      end

      # --- Normalizers (private) ---
      private

      # Normalize where arguments into an array of string fragments safe for Typesense.
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
            fragments << entry.to_s
            i += 1
          when Array
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
      def normalize_order(value)
        return [] if value.nil?

        case value
        when Hash
          value.flat_map do |k, dir|
            if dir.is_a?(Hash)
              assoc = k.to_sym
              @klass.join_for(assoc)
              SearchEngine::Joins::Guard.ensure_join_applied!(joins_list, assoc, context: 'sorting')

              dir.flat_map do |field_name, d|
                field = field_name.to_s.strip
                raise ArgumentError, 'order: field name must be non-empty' if field.empty?

                begin
                  cfg = @klass.join_for(assoc)
                  SearchEngine::Joins::Guard.validate_joined_field!(cfg, field)
                rescue StandardError
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
                raise ArgumentError,
                      "order: direction must be :asc or :desc (got #{dir.inspect} for field #{k.inspect})"
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
          value.flat_map { |v| normalize_order(v) }
        when Symbol
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
            suggestions = suggest_fields(name.to_sym, known_attrs.keys.map(&:to_sym))
            suggest = if suggestions.empty?
                        ''
                      elsif suggestions.length == 1
                        " (did you mean :#{suggestions.first}?)"
                      else
                        last = suggestions.last
                        others = suggestions[0..-2].map { |s| ":#{s}" }.join(', ')
                        " (did you mean #{others}, or :#{last}?)"
                      end
            raise SearchEngine::Errors::UnknownField,
                  "UnknownField: unknown field #{name.inspect} for #{klass_name_for_inspect}#{suggest}"
          end

          ordered << name unless ordered.include?(name)
        end
        ordered
      end

      # Extended normalization supporting nested association selections.
      # Returns a Hash with keys: :base, :nested, :nested_order.
      def normalize_select_input(fields, context: 'selecting fields')
        list = Array(fields).flatten.compact
        return { base: [], nested: {}, nested_order: [] } if list.empty?

        base = []
        nested = {}
        nested_order = []

        add_base = ->(val) { base.concat(normalize_select([val])) }

        add_nested = lambda do |assoc, values|
          key = assoc.to_sym
          @klass.join_for(key)
          SearchEngine::Joins::Guard.ensure_join_applied!(joins_list, key, context: context)

          items = case values
                  when Array then values
                  when nil then []
                  else [values]
                  end
          names = items.flatten.compact.map(&:to_s).map(&:strip).reject(&:empty?)
          return if names.empty?

          cfg = @klass.join_for(key)
          names.each do |fname|
            SearchEngine::Joins::Guard.validate_joined_field!(cfg, fname, source_klass: @klass)
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
            raise SearchEngine::Errors::ConflictingSelection,
                  "ConflictingSelection: unsupported input #{entry.class} in selection"
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

        field_str = field.to_s
        if field_str.start_with?('$') || field_str.include?('.')
          raise SearchEngine::Errors::UnsupportedGroupField.new(
            %(UnsupportedGroupField: grouping supports base fields only (got #{field_str.inspect})),
            doc: 'docs/grouping.md#troubleshooting',
            details: { field: field_str }
          )
        end

        attrs = safe_attributes_map
        unless attrs.nil? || attrs.empty?
          sym = field.to_sym
          unless attrs.key?(sym)
            msg = build_invalid_group_unknown_field_message(sym)
            raise SearchEngine::Errors::InvalidGroup.new(
              msg,
              doc: 'docs/grouping.md#troubleshooting',
              details: { field: sym }
            )
          end
        end

        if !limit.nil? && !(limit.is_a?(Integer) && limit >= 1)
          got = limit.nil? ? 'nil' : limit.inspect
          raise SearchEngine::Errors::InvalidGroup.new(
            "InvalidGroup: limit must be a positive integer (got #{got})",
            doc: 'docs/grouping.md#troubleshooting',
            details: { limit: limit }
          )
        end

        unless [true, false].include?(missing_values)
          raise SearchEngine::Errors::InvalidGroup.new(
            "InvalidGroup: missing_values must be boolean (got #{missing_values.inspect})",
            doc: 'docs/grouping.md#troubleshooting',
            details: { missing_values: missing_values }
          )
        end

        { field: field.to_sym, limit: limit, missing_values: missing_values }
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

        names.each { |name| @klass.join_for(name) }
        names
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

      # Lightweight suggestion helper using Levenshtein; returns up to 3 candidates.
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
        sorted = distances.sort_by { |(_cand, d)| d }
        threshold = 2
        sorted.take(3).select { |(_cand, d)| d <= threshold }.map { |cand, _d| cand.to_sym }
      end

      # Highlight/ranking/curation normalizers used by chainers and initial state
      def normalize_highlight_input(value)
        h = value || {}
        raise SearchEngine::Errors::InvalidOption, 'highlight must be a Hash of options' unless h.is_a?(Hash)

        fields = Array(h[:fields] || h['fields']).flatten.compact.map { |f| f.to_s.strip }.reject(&:empty?)
        full_fields = Array(h[:full_fields] || h['full_fields']).flatten.compact.map do |f|
          f.to_s.strip
        end.reject(&:empty?)
        start_tag = h[:start_tag] || h['start_tag']
        end_tag = h[:end_tag] || h['end_tag']
        affix = h.key?(:affix_tokens) ? h[:affix_tokens] : h['affix_tokens']
        snippet = h.key?(:snippet_threshold) ? h[:snippet_threshold] : h['snippet_threshold']

        affix = nil if affix.nil?
        affix = coerce_integer_min(affix, :highlight_affix_num_tokens, 0) unless affix.nil?
        snippet = nil if snippet.nil?
        snippet = coerce_integer_min(snippet, :highlight_snippet_threshold, 0) unless snippet.nil?

        {
          fields: fields,
          full_fields: full_fields,
          start_tag: start_tag&.to_s,
          end_tag: end_tag&.to_s,
          affix_tokens: affix,
          snippet_threshold: snippet
        }
      end

      def normalize_ranking_input(value)
        h = value || {}
        unless h.is_a?(Hash)
          raise SearchEngine::Errors::InvalidOption.new(
            'InvalidOption: ranking expects a Hash of options',
            hint: 'Use ranking(num_typos: 1, drop_tokens_threshold: 0.2,'\
                  'prioritize_exact_match: true, query_by_weights: { name: 2 })',
            doc: 'docs/ranking.md#options'
          )
        end

        out = {}

        if h.key?(:num_typos) || h.key?('num_typos')
          raw = h[:num_typos] || h['num_typos']
          unless raw.nil?
            begin
              iv = Integer(raw)
              unless [0, 1, 2].include?(iv)
                raise SearchEngine::Errors::InvalidOption.new(
                  "InvalidOption: num_typos must be 0, 1, or 2 (got #{raw.inspect})",
                  doc: 'docs/ranking.md#options'
                )
              end
              out[:num_typos] = iv
            rescue ArgumentError, TypeError
              raise SearchEngine::Errors::InvalidOption.new(
                "InvalidOption: num_typos must be an Integer in {0,1,2} (got #{raw.inspect})",
                doc: 'docs/ranking.md#options'
              )
            end
          end
        end

        if h.key?(:drop_tokens_threshold) || h.key?('drop_tokens_threshold')
          raw = h[:drop_tokens_threshold] || h['drop_tokens_threshold']
          unless raw.nil?
            begin
              fv = Float(raw)
              unless fv >= 0.0 && fv <= 1.0 && fv.finite?
                raise SearchEngine::Errors::InvalidOption.new(
                  "InvalidOption: drop_tokens_threshold must be a float between 0.0 and 1.0 (got #{raw.inspect})",
                  doc: 'docs/ranking.md#options'
                )
              end
              out[:drop_tokens_threshold] = fv
            rescue ArgumentError, TypeError
              raise SearchEngine::Errors::InvalidOption.new(
                "InvalidOption: drop_tokens_threshold must be a float between 0.0 and 1.0 (got #{raw.inspect})",
                doc: 'docs/ranking.md#options'
              )
            end
          end
        end

        if h.key?(:prioritize_exact_match) || h.key?('prioritize_exact_match')
          raw = h[:prioritize_exact_match] || h['prioritize_exact_match']
          out[:prioritize_exact_match] = raw.nil? ? nil : coerce_boolean_strict(raw, :prioritize_exact_match)
        end

        if h.key?(:query_by_weights) || h.key?('query_by_weights')
          raw = h[:query_by_weights] || h['query_by_weights']
          unless raw.nil?
            unless raw.is_a?(Hash)
              raise SearchEngine::Errors::InvalidOption.new(
                'InvalidOption: query_by_weights must be a Hash of { field => Integer }',
                doc: 'docs/ranking.md#weights'
              )
            end
            normalized = {}
            raw.each do |k, v|
              key = k.to_s.strip
              next if key.empty?

              begin
                w = Integer(v)
              rescue ArgumentError, TypeError
                raise SearchEngine::Errors::InvalidOption.new(
                  "InvalidOption: weight for #{k.inspect} must be an Integer >= 0",
                  doc: 'docs/ranking.md#weights',
                  details: { field: k, weight: v }
                )
              end
              if w.negative?
                raise SearchEngine::Errors::InvalidOption.new(
                  "InvalidOption: weight for #{k.inspect} must be >= 0",
                  doc: 'docs/ranking.md#weights',
                  details: { field: k, weight: v }
                )
              end
              normalized[key] = w
            end
            out[:query_by_weights] = normalized
          end
        end

        out
      end

      def normalize_curation_ids(values)
        list = Array(values).flatten(1).compact
        list.map { |v| v.to_s.strip }.reject(&:empty?)
      end

      def normalize_curation_tags(values)
        list = Array(values).flatten(1).compact.map { |v| v.to_s.strip }.reject(&:empty?)
        list.each_with_object([]) { |t, acc| acc << t unless acc.include?(t) }
      end

      def normalize_curation_input(value)
        return nil if value.nil? || (value.respond_to?(:empty?) && value.empty?)
        raise ArgumentError, 'curation must be a Hash' unless value.is_a?(Hash)

        pinned = normalize_curation_ids(value[:pinned] || value['pinned'])
        hidden = normalize_curation_ids(value[:hidden] || value['hidden'])
        tags = normalize_curation_tags(value[:override_tags] || value['override_tags'])

        raw_fch = (value.key?(:filter_curated_hits) ? value[:filter_curated_hits] : value['filter_curated_hits'])
        fch = raw_fch.nil? ? nil : coerce_boolean_strict(raw_fch, :filter_curated_hits)

        { pinned: pinned, hidden: hidden, override_tags: tags, filter_curated_hits: fch }
      end
    end
  end
end
