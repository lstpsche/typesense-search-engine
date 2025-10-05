# frozen_string_literal: true

module SearchEngine
  module Hydration
    # Centralized executors for materialization: to_a/each/count/ids/pluck.
    # Accepts a Relation instance; never mutates it; performs at most one HTTP call
    # per relation instance by reusing its internal memoization lock.
    module Materializers
      module_function

      # Execute the relation and return a Result, memoizing on the relation.
      # @param relation [SearchEngine::Relation]
      # @return [SearchEngine::Result]
      def execute(relation)
        loaded = relation.instance_variable_get(:@__loaded)
        memo = relation.instance_variable_get(:@__result_memo)
        return memo if loaded && memo

        load_lock = relation.instance_variable_get(:@__load_lock)
        load_lock.synchronize do
          loaded = relation.instance_variable_get(:@__loaded)
          memo = relation.instance_variable_get(:@__result_memo)
          return memo if loaded && memo

          collection = relation.send(:collection_name_for_klass)
          params = SearchEngine::CompiledParams.from(relation.to_typesense_params)
          url_opts = relation.send(:build_url_opts)

          raw_result = relation.send(:client).search(collection: collection, params: params, url_opts: url_opts)

          selection_ctx = SearchEngine::Hydration::SelectionContext.build(relation)
          facets_ctx = build_facets_context_from_state(relation)

          result = if selection_ctx || facets_ctx
                     SearchEngine::Result.new(
                       raw_result.raw,
                       klass: relation.klass,
                       selection: selection_ctx,
                       facets: facets_ctx
                     )
                   else
                     raw_result
                   end

          relation.send(:enforce_hit_validator_if_needed!, result.found, collection: collection)
          relation.instance_variable_set(:@__result_memo, result)
          relation.instance_variable_set(:@__loaded, true)
          result
        end
      end

      # --- Public materializers (delegation targets) ------------------------

      def to_a(relation)
        result = execute(relation)
        result.to_a
      end

      def each(relation, &block)
        result = execute(relation)
        block_given? ? result.each(&block) : result.each
      end

      def first(relation, n = nil)
        arr = to_a(relation)
        return arr.first if n.nil?

        arr.first(n)
      end

      def last(relation, n = nil)
        arr = to_a(relation)
        return arr.last if n.nil?

        arr.last(n)
      end

      def take(relation, n = 1)
        arr = to_a(relation)
        return arr.first if n == 1

        arr.first(n)
      end

      def ids(relation)
        pluck(relation, :id)
      end

      def pluck(relation, *fields)
        raise ArgumentError, 'pluck requires at least one field' if fields.nil? || fields.empty?

        names = coerce_pluck_field_names(fields)
        validate_pluck_fields_allowed!(relation, names)

        result = execute(relation)
        raw_hits = Array(result.raw['hits'])
        objects = result.to_a

        enforce_strict_for_pluck_row = lambda do |doc, requested|
          present_keys = doc.keys.map(&:to_s)
          if result.respond_to?(:send)
            ctx = result.instance_variable_get(:@selection_ctx) || {}
            if ctx[:strict_missing] == true
              result.send(:enforce_strict_missing_if_needed!, present_keys, requested_override: requested)
            end
          end
        end

        if names.length == 1
          field = names.first
          return objects.each_with_index.map do |obj, idx|
            doc = (raw_hits[idx] && raw_hits[idx]['document']) || {}
            # Enforce strict missing for the requested field against present keys
            enforce_strict_for_pluck_row.call(doc, [field])
            if obj.respond_to?(field)
              obj.public_send(field)
            else
              doc[field]
            end
          end
        end

        objects.each_with_index.map do |obj, idx|
          doc = (raw_hits[idx] && raw_hits[idx]['document']) || {}
          # Enforce strict missing for all requested fields against present keys
          enforce_strict_for_pluck_row.call(doc, names)
          names.map do |field|
            if obj.respond_to?(field)
              obj.public_send(field)
            else
              doc[field]
            end
          end
        end
      end

      def exists?(relation)
        loaded = relation.instance_variable_get(:@__loaded)
        memo = relation.instance_variable_get(:@__result_memo)
        return memo.found.to_i.positive? if loaded && memo

        fetch_found_only(relation).positive?
      end

      def count(relation)
        if relation.send(:curation_filter_curated_hits?)
          to_a(relation)
          return relation.send(:curated_indices_for_current_result).size
        end

        loaded = relation.instance_variable_get(:@__loaded)
        memo = relation.instance_variable_get(:@__result_memo)
        return memo.found.to_i if loaded && memo

        fetch_found_only(relation)
      end

      # --- internals --------------------------------------------------------

      def fetch_found_only(relation)
        collection = relation.send(:collection_name_for_klass)
        base = SearchEngine::CompiledParams.from(relation.to_typesense_params).to_h

        minimal = base.dup
        minimal[:per_page] = 1
        minimal[:page] = 1
        minimal[:include_fields] = 'id'

        url_opts = relation.send(:build_url_opts)
        result = relation.send(:client).search(collection: collection, params: minimal, url_opts: url_opts)
        count = result.found.to_i
        relation.send(:enforce_hit_validator_if_needed!, count, collection: collection)
        count
      end
      module_function :fetch_found_only

      def coerce_pluck_field_names(fields)
        Array(fields).flatten.compact.map(&:to_s).map(&:strip).reject(&:empty?)
      end
      module_function :coerce_pluck_field_names

      def validate_pluck_fields_allowed!(relation, names)
        state = relation.instance_variable_get(:@state) || {}
        include_base = Array(state[:select]).map(&:to_s)
        exclude_base = Array(state[:exclude]).map(&:to_s)

        missing = if include_base.empty?
                    names & exclude_base
                  else
                    allowed = include_base - exclude_base
                    names - allowed
                  end

        return if missing.empty?

        msg = build_invalid_selection_message_for_pluck(
          missing: missing,
          requested: names,
          include_base: include_base,
          exclude_base: exclude_base
        )
        field = missing.map(&:to_s).min
        hint = exclude_base.include?(field) ? "Remove exclude(:#{field})." : nil
        raise SearchEngine::Errors::InvalidSelection.new(
          msg,
          hint: hint,
          doc: 'docs/field_selection.md#guardrails',
          details: { requested: names, include_base: include_base, exclude_base: exclude_base }
        )
      end
      module_function :validate_pluck_fields_allowed!

      def build_invalid_selection_message_for_pluck(missing:, requested:, include_base:, exclude_base:)
        field = missing.map(&:to_s).min
        if exclude_base.include?(field)
          "InvalidSelection: field :#{field} not in effective selection. Remove exclude(:#{field})."
        else
          suggestion_fields = include_base.dup
          requested.each { |f| suggestion_fields << f unless suggestion_fields.include?(f) }
          symbols = suggestion_fields.map { |t| ":#{t}" }.join(',')
          "InvalidSelection: field :#{field} not in effective selection. Use `reselect(#{symbols})`."
        end
      end
      module_function :build_invalid_selection_message_for_pluck

      def build_facets_context_from_state(relation)
        state = relation.instance_variable_get(:@state) || {}
        fields = Array(state[:facet_fields]).map(&:to_s)
        queries = Array(state[:facet_queries]).map do |q|
          h = { field: q[:field].to_s, expr: q[:expr].to_s }
          h[:label] = q[:label].to_s if q[:label]
          h
        end
        return nil if fields.empty? && queries.empty?

        { fields: fields.freeze, queries: queries.freeze }.freeze
      end
      module_function :build_facets_context_from_state
    end
  end
end
