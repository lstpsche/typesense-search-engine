# frozen_string_literal: true

module SearchEngine
  module Hydration
    # Pure builder for selection and hydration context consumed by Result.
    # Computes effective base and nested selections and strict-missing policy.
    module SelectionContext
      # Build selection context from an immutable relation instance.
      # @param relation [SearchEngine::Relation]
      # @return [Hash, nil] frozen context or nil when no selection and no strict flag
      def self.build(relation)
        state = snapshot_state(relation)

        include_base, exclude_base, include_nested, exclude_nested, nested_order = extract_selection_maps(state)

        nothing_selected = include_base.empty? && maps_all_empty?(include_nested)
        nothing_excluded = exclude_base.empty? && maps_all_empty?(exclude_nested)

        effective_base = compute_effective_base(include_base, exclude_base)
        nested_effective = compute_nested_effective(include_nested, exclude_nested, nested_order)

        strict_missing = strict_missing_flag(state)
        requested_root = effective_base

        selection = {}
        selection[:base] = effective_base unless effective_base.empty?
        selection[:nested] = nested_effective unless nested_effective.empty?
        selection[:strict_missing] = true if strict_missing
        selection[:requested_root] = requested_root unless requested_root.empty?

        return nil if selection.empty? && nothing_selected && nothing_excluded

        selection.freeze
      end

      # --- helpers ----------------------------------------------------------

      def self.snapshot_state(relation)
        relation.instance_variable_get(:@state) || {}
      end
      private_class_method :snapshot_state

      def self.extract_selection_maps(state)
        include_base = Array(state[:select]).map(&:to_s)
        include_nested = (state[:select_nested] || {}).transform_values { |arr| Array(arr).map(&:to_s) }
        exclude_base = Array(state[:exclude]).map(&:to_s)
        exclude_nested = (state[:exclude_nested] || {}).transform_values { |arr| Array(arr).map(&:to_s) }
        nested_order = Array(state[:select_nested_order])
        [include_base, exclude_base, include_nested, exclude_nested, nested_order]
      end
      private_class_method :extract_selection_maps

      def self.compute_effective_base(include_base, exclude_base)
        return [] if include_base.empty?

        (include_base - exclude_base).map(&:to_s).reject(&:empty?)
      end
      private_class_method :compute_effective_base

      def self.compute_nested_effective(include_nested, exclude_nested, nested_order)
        out = {}
        nested_order.each do |assoc|
          inc = Array(include_nested[assoc]).map(&:to_s)
          next if inc.empty?

          exc = Array(exclude_nested[assoc]).map(&:to_s)
          eff = (inc - exc)
          out[assoc] = eff unless eff.empty?
        end
        out
      end
      private_class_method :compute_nested_effective

      def self.strict_missing_flag(state)
        opts = state[:options] || {}
        sel = opts[:selection] || opts['selection'] || {}
        if sel.key?(:strict_missing) || sel.key?('strict_missing')
          val = sel[:strict_missing]
          val = sel['strict_missing'] if val.nil?
          return true if val == true || val.to_s == 'true'

          return false
        end
        SearchEngine.config.selection.strict_missing ? true : false
      rescue StandardError
        false
      end
      private_class_method :strict_missing_flag

      def self.maps_all_empty?(map)
        Array(map.values).all? { |v| Array(v).empty? }
      end
      private_class_method :maps_all_empty?
    end
  end
end
