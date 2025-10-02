# frozen_string_literal: true

module SearchEngine
  module DSL
    # Safe parser that converts Relation#where inputs into validated AST nodes.
    #
    # Supported inputs:
    # - Hash: { field => value } (scalar => Eq, Array => In)
    # - Raw String: full Typesense fragment (escape hatch) => Raw
    # - Fragment + args: ["price > ?", 100] or ["brand_id IN ?", [1,2,3]]
    #
    # Validation/coercion:
    # - Field names validated against model attributes (when available)
    # - Booleans coerced from "true"/"false" strings when attribute type is boolean
    # - Date/DateTime coerced to Time.utc; Arrays flattened one level and compacted
    module Parser
      module_function

      # Parse a where input into AST nodes.
      #
      # Return convention:
      # - Single predicate => a single AST node
      # - Hash with multiple keys or list-of-inputs => Array<AST::Node>
      #
      # @param input [Hash, String, Array]
      # @param args [Array] optional, used only when +input+ is a template String
      # @param klass [Class] SearchEngine::Base subclass used for attribute validation
      # @return [SearchEngine::AST::Node, Array<SearchEngine::AST::Node>]
      # @raise [ArgumentError] on template mismatch, unknown fields, or invalid arrays
      def parse(input, klass:, args: [])
        case input
        when Hash
          parse_hash(input, klass: klass)
        when String
          if placeholders?(input)
            needed = count_placeholders(input)
            ensure_placeholder_arity!(needed, args.length, input)
            parse_template(input, args, klass: klass)
          else
            parse_raw(input)
          end
        when Array
          parse_array_input(input, klass: klass)
        when Symbol
          # Back-compat: treat symbol as raw fragment name
          parse_raw(input.to_s)
        else
          raise ArgumentError, "Parser: unsupported input #{input.class}"
        end
      end

      # Parse a list of heterogenous where arguments (as passed to Relation#where).
      # @param list [Array]
      # @param klass [Class]
      # @return [Array<SearchEngine::AST::Node>]
      def parse_list(list, klass:)
        items = Array(list).flatten.compact
        return [] if items.empty?

        nodes = []
        i = 0
        while i < items.length
          entry = items[i]
          case entry
          when Hash
            nodes.concat(Array(parse_hash(entry, klass: klass)))
            i += 1
          when String
            if placeholders?(entry)
              needed = count_placeholders(entry)
              args_for_template = items[(i + 1)..(i + needed)] || []
              ensure_placeholder_arity!(needed, args_for_template.length, entry)
              nodes << parse_template(entry, args_for_template, klass: klass)
              i += 1 + needed
            else
              nodes << parse_raw(entry)
              i += 1
            end
          when Symbol
            nodes << parse_raw(entry.to_s)
            i += 1
          when Array
            nodes << parse_array_entry(entry, klass: klass)
            i += 1
          else
            raise ArgumentError, "Parser: unsupported where argument #{entry.class}"
          end
        end
        nodes
      end

      # --- Internals -------------------------------------------------------

      def parse_array_entry(entry, klass:)
        return parse_raw(entry.to_s) unless entry.first.is_a?(String)
        return parse_list(entry, klass: klass) unless placeholders?(entry.first)

        template = entry.first
        args_list = if entry.length == 2 && entry[1].is_a?(Array)
                      [entry[1]]
                    else
                      entry[1..]
                    end
        needed = count_placeholders(template)
        ensure_placeholder_arity!(needed, Array(args_list).length, template)
        parse_template(template, Array(args_list), klass: klass)
      end

      def parse_hash(hash, klass:)
        raise ArgumentError, 'Parser: hash input must be a Hash' unless hash.is_a?(Hash)

        attrs = safe_attributes_map(klass)
        validate_hash_keys!(hash, attrs, klass)

        pairs = hash.map do |k, v|
          field = k.to_sym
          value = v

          if array_like?(value)
            values = normalize_array_values(value, field: field, klass: klass)
            ensure_non_empty_values!(values)
            SearchEngine::AST.in_(field, values)
          else
            coerced = coerce_value_for_field(value, field: field, klass: klass)
            SearchEngine::AST.eq(field, coerced)
          end
        end

        return pairs.first if pairs.length == 1

        pairs
      end

      def parse_template(template, args, klass:)
        raise ArgumentError, 'Parser: template must be a String' unless template.is_a?(String)

        args = Array(args)
        m = template.match(/\A\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=|!=|>=|<=|>|<|IN|NOT\s+IN|MATCHES|PREFIX)\s*\?\s*\z/i)
        raise ArgumentError, "Parser: invalid template '#{template}'" unless m

        field_raw = m[1]
        op = m[2].upcase.gsub(/\s+/, ' ')

        field_sym = field_raw.to_sym
        attrs = safe_attributes_map(klass)
        validate_field!(field_sym, attrs, klass)

        case op
        when '='
          SearchEngine::AST.eq(field_sym, coerce_value_for_field(args.first, field: field_sym, klass: klass))
        when '!='
          SearchEngine::AST.not_eq(field_sym, coerce_value_for_field(args.first, field: field_sym, klass: klass))
        when '>'
          SearchEngine::AST.gt(field_sym, coerce_value_for_field(args.first, field: field_sym, klass: klass))
        when '>='
          SearchEngine::AST.gte(field_sym, coerce_value_for_field(args.first, field: field_sym, klass: klass))
        when '<'
          SearchEngine::AST.lt(field_sym, coerce_value_for_field(args.first, field: field_sym, klass: klass))
        when '<='
          SearchEngine::AST.lte(field_sym, coerce_value_for_field(args.first, field: field_sym, klass: klass))
        when 'IN'
          values = normalize_array_values(args.first, field: field_sym, klass: klass)
          ensure_non_empty_values!(values)
          SearchEngine::AST.in_(field_sym, values)
        when 'NOT IN'
          values = normalize_array_values(args.first, field: field_sym, klass: klass)
          ensure_non_empty_values!(values)
          SearchEngine::AST.not_in(field_sym, values)
        when 'MATCHES'
          SearchEngine::AST.matches(field_sym, args.first)
        when 'PREFIX'
          SearchEngine::AST.prefix(field_sym, String(args.first))
        else
          raise ArgumentError, "Parser: unsupported operator '#{op}'"
        end
      end

      def parse_raw(fragment)
        SearchEngine::AST.raw(String(fragment))
      end

      # Heuristic: treat an Array input as a template+args when it starts with a
      # String that has placeholders; otherwise treat as list-of-inputs.
      def parse_array_input(arr, klass:)
        return [] if arr.nil?

        arr = Array(arr)

        if arr.first.is_a?(String) && placeholders?(arr.first) && arr.length >= 2
          template = arr.first
          args_list = if arr.length == 2 && arr[1].is_a?(Array)
                        [arr[1]]
                      else
                        arr[1..]
                      end
          needed = count_placeholders(template)
          ensure_placeholder_arity!(needed, Array(args_list).length, template)
          parse_template(template, Array(args_list), klass: klass)
        else
          parse_list(arr, klass: klass)
        end
      end

      # --- Utilities -------------------------------------------------------

      def placeholders?(str)
        str.is_a?(String) && SearchEngine::Filters::Sanitizer.count_placeholders(str).positive?
      end

      def count_placeholders(str)
        SearchEngine::Filters::Sanitizer.count_placeholders(str)
      end

      def ensure_placeholder_arity!(needed, provided, template)
        return if needed == provided

        raise ArgumentError,
              "Parser: expected #{needed} args for #{needed} placeholders in template '#{template}', got #{provided}."
      end

      def safe_attributes_map(klass)
        if klass.respond_to?(:attributes)
          klass.attributes || {}
        else
          {}
        end
      end

      def validate_hash_keys!(hash, attributes_map, klass)
        return if hash.nil? || hash.empty?

        known = attributes_map.keys.map(&:to_sym)
        unknown = hash.keys.map(&:to_sym) - known
        return if unknown.empty?

        klass_name = klass.respond_to?(:name) && klass.name ? klass.name : klass.to_s
        known_list = known.map(&:to_s).sort.join(', ')
        unknown_name = unknown.first.inspect
        raise ArgumentError, "Unknown attribute #{unknown_name} for #{klass_name}. Known: #{known_list}"
      end

      def validate_field!(field, attributes_map, klass)
        return if attributes_map.nil? || attributes_map.empty?

        sym = field.to_sym
        return if attributes_map.key?(sym)

        klass_name = klass.respond_to?(:name) && klass.name ? klass.name : klass.to_s
        known_list = attributes_map.keys.map(&:to_s).sort.join(', ')
        raise ArgumentError, "Unknown attribute #{sym.inspect} for #{klass_name}. Known: #{known_list}"
      end

      def array_like?(value)
        value.is_a?(Array)
      end

      def normalize_array_values(value, field:, klass:)
        arr = Array(value).flatten(1).compact
        arr.map { |v| coerce_value_for_field(v, field: field, klass: klass) }
      end

      def ensure_non_empty_values!(values)
        return if values.is_a?(Array) && !values.empty?

        raise ArgumentError, "Parser: values for IN must be a non-empty Array (got #{values.inspect})."
      end

      def coerce_value_for_field(value, field:, klass:)
        type = begin
          safe_attributes_map(klass)[field.to_sym]
        rescue StandardError
          nil
        end
        coerce_value(value, type_hint: type)
      end

      def coerce_value(value, type_hint: nil)
        # Booleans from strings when type is boolean
        if type_boolean?(type_hint) && value.is_a?(String)
          lc = value.strip.downcase
          return true if lc == 'true'
          return false if lc == 'false'
        end

        # Date/DateTime -> Time UTC
        case value
        when DateTime
          return value.to_time.utc
        when Date
          # Date#to_time may be local; normalize to UTC midnight
          return value.to_time.utc
        else
          # Time as-is; ensure Time is UTC if it responds
          return value.utc if value.is_a?(Time) && !value.utc?
        end

        value
      end

      def type_boolean?(hint)
        case hint
        when :boolean, 'boolean', TrueClass, FalseClass then true
        else false
        end
      end
    end
  end
end
