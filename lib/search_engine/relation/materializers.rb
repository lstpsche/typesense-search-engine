# frozen_string_literal: true

module SearchEngine
  class Relation
    # Materializers and execution path (one network call per Relation instance).
    module Materializers
      # Return a shallow copy of hydrated hits.
      # @return [Array<Object>]
      def to_a
        ensure_loaded!
        @__result_memo.to_a
      end

      # Iterate over hydrated hits.
      # @yieldparam obj [Object]
      # @return [Enumerator] when no block is given
      def each(&block)
        ensure_loaded!
        return @__result_memo.each unless block_given?

        @__result_memo.each(&block)
      end

      # Return the first element or the first N elements from the loaded page.
      # @param n [Integer, nil]
      # @return [Object, Array<Object>]
      def first(n = nil)
        ensure_loaded!
        return @__result_memo.to_a.first if n.nil?

        @__result_memo.to_a.first(n)
      end

      # Return the last element or the last N elements from the currently fetched page.
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

      # Pluck one or multiple fields.
      # @param fields [Array<#to_sym,#to_s>]
      # @return [Array<Object>, Array<Array<Object>>]
      def pluck(*fields)
        raise ArgumentError, 'pluck requires at least one field' if fields.nil? || fields.empty?

        names = coerce_pluck_field_names(fields)
        validate_pluck_fields_allowed!(names)

        ensure_loaded!
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

      # Whether any matching documents exist.
      # @return [Boolean]
      def exists?
        return @__result_memo.found.to_i.positive? if @__loaded && @__result_memo

        fetch_found_only.positive?
      end

      # Return total number of matching documents.
      # @return [Integer]
      def count
        if curation_filter_curated_hits?
          ensure_loaded!
          return curated_indices_for_current_result.size
        end

        return @__result_memo.found.to_i if @__loaded && @__result_memo

        fetch_found_only
      end

      protected

      # Ensure the relation has executed the search and memoized the Result.
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
      # @return [SearchEngine::Result]
      def execute
        collection = collection_name_for_klass
        params = to_typesense_params

        url_opts = build_url_opts
        result = client.search(collection: collection, params: params, url_opts: url_opts)
        selection_ctx = build_selection_context
        facets_ctx = build_facets_context
        if selection_ctx || facets_ctx
          result = SearchEngine::Result.new(result.raw, klass: @klass, selection: selection_ctx, facets: facets_ctx)
        end
        enforce_hit_validator_if_needed!(result.found, collection: collection)
        @__result_memo = result
        @__loaded = true
        result
      end

      # Perform a minimal request to obtain only the total `found` count.
      # @return [Integer]
      def fetch_found_only
        collection = collection_name_for_klass
        base = to_typesense_params

        minimal = base.dup
        minimal[:per_page] = 1
        minimal[:page] = 1
        minimal[:include_fields] = 'id'

        url_opts = build_url_opts
        result = client.search(collection: collection, params: minimal, url_opts: url_opts)
        count = result.found.to_i
        enforce_hit_validator_if_needed!(count, collection: collection)
        count
      end

      # --- Helpers used by materializers and pluck validation ---

      def coerce_pluck_field_names(fields)
        Array(fields).flatten.compact.map(&:to_s).map(&:strip).reject(&:empty?)
      end

      def validate_pluck_fields_allowed!(names)
        include_base = Array(@state[:select]).map(&:to_s)
        exclude_base = Array(@state[:exclude]).map(&:to_s)

        missing =
          if include_base.empty?
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

      def curated_indices_for_current_result
        @__result_memo.to_a.each_with_index.select do |obj, _idx|
          obj.respond_to?(:curated_hit?) && obj.curated_hit?
        end.map(&:last)
      end

      def curation_filter_curated_hits?
        @state[:curation] && @state[:curation][:filter_curated_hits]
      end

      def selection_maps_all_empty?(map)
        Array(map.values).all? { |v| Array(v).empty? }
      end

      def build_selection_context # rubocop:disable Metrics/PerceivedComplexity
        include_base = Array(@state[:select]).map(&:to_s)
        include_nested = (@state[:select_nested] || {}).transform_values { |arr| Array(arr).map(&:to_s) }
        exclude_base = Array(@state[:exclude]).map(&:to_s)
        exclude_nested = (@state[:exclude_nested] || {}).transform_values { |arr| Array(arr).map(&:to_s) }

        nothing_selected = include_base.empty? && selection_maps_all_empty?(include_nested)
        nothing_excluded = exclude_base.empty? && selection_maps_all_empty?(exclude_nested)
        return nil if nothing_selected && nothing_excluded

        effective_base = include_base.empty? ? nil : (include_base - exclude_base).map(&:to_s).reject(&:empty?)

        nested_effective = {}
        Array(@state[:select_nested_order]).each do |assoc|
          inc = Array(include_nested[assoc]).map(&:to_s)
          next if inc.empty?

          exc = Array(exclude_nested[assoc]).map(&:to_s)
          eff = (inc - exc)
          nested_effective[assoc] = eff unless eff.empty?
        end

        selection = {}
        selection[:base] = effective_base unless effective_base.nil?
        selection[:nested] = nested_effective unless nested_effective.empty?

        selection unless selection.empty?
      end

      def build_facets_context
        fields = Array(@state[:facet_fields]).map(&:to_s)
        queries = Array(@state[:facet_queries]).map do |q|
          h = { field: q[:field].to_s, expr: q[:expr].to_s }
          h[:label] = q[:label].to_s if q[:label]
          h
        end
        return nil if fields.empty? && queries.empty?

        { fields: fields.freeze, queries: queries.freeze }.freeze
      end

      def collection_name_for_klass
        return @klass.collection if @klass.respond_to?(:collection) && @klass.collection

        begin
          mapping = SearchEngine::Registry.mapping
          found = mapping.find { |(_, kls)| kls == @klass }
          return found.first if found
        rescue StandardError
        end

        raise ArgumentError, "Unknown collection for #{klass_name_for_inspect}"
      end

      def client
        @__client ||= (
          SearchEngine.config.respond_to?(:client) && SearchEngine.config.client
        ) || SearchEngine::Client.new
      end
    end
  end
end
