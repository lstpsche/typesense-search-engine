# frozen_string_literal: true

module SearchEngine
  module Filters
    # Sanitizer utilities for Typesense-compatible filters.
    #
    # Provides quoting/escaping and helpers to build normalized filter strings
    # from hashes and templates with placeholders.
    module Sanitizer
      module_function

      # Quote a Ruby value into a Typesense filter literal.
      #
      # - NilClass => "null"
      # - TrueClass/FalseClass => "true"/"false"
      # - Numeric => as-is (stringified)
      # - String => double-quoted with minimal escaping for \ and "
      # - Time/DateTime/Date => ISO8601 string, then quoted as a string
      # - Array => one-level flatten, each element quoted, wrapped with [ ... ]
      #
      # @param value [Object]
      # @return [String]
      def quote(value)
        case value
        when NilClass
          'null'
        when TrueClass
          'true'
        when FalseClass
          'false'
        when Numeric
          value.to_s
        when String
          %("#{escape_string(value)}")
        when Time
          %("#{value.iso8601}")
        when DateTime
          %("#{value.iso8601}")
        when Date
          %("#{value.iso8601}")
        when Array
          elements = value.flatten(1).map { |el| quote(el) }
          "[#{elements.join(', ')}]"
        else
          if value.respond_to?(:to_time)
            %("#{value.to_time.iso8601}")
          else
            %("#{escape_string(value.to_s)}")
          end
        end
      end

      # Build normalized filter fragments from a Hash.
      # Scalars become "field:=<quoted>", arrays become "field:=<quoted_list>".
      #
      # @param hash [Hash{#to_sym=>Object}]
      # @param _attributes_map [Hash] (ignored here; validation should be done by caller)
      # @return [Array<String>]
      def build_from_hash(hash, _attributes_map = nil)
        raise ArgumentError, 'filters hash must be a Hash' unless hash.is_a?(Hash)

        hash.map do |key, raw|
          field = key.to_sym.to_s
          if array_like?(raw)
            "#{field}:=#{quote(Array(raw))}"
          else
            "#{field}:=#{quote(raw)}"
          end
        end
      end

      # Apply placeholder substitution for templates with '?' markers.
      #
      # Each unescaped '?' is replaced with a quoted argument from +args+ in order.
      #
      # @param template [String]
      # @param args [Array<Object>]
      # @return [String]
      def apply_placeholders(template, args)
        raise ArgumentError, 'template must be a String' unless template.is_a?(String)
        raise ArgumentError, 'args must be an Array' unless args.is_a?(Array)

        needed = count_placeholders(template)
        provided = args.length
        raise ArgumentError, "expected #{needed} args for #{needed} placeholders, got #{provided}" if needed != provided

        idx = -1
        template.gsub(/(?<!\\)\?/) do
          idx += 1
          quote(args[idx])
        end
      end

      # Count unescaped '?' placeholders.
      # @param template [String]
      # @return [Integer]
      def count_placeholders(template)
        count = 0
        escaped = false
        template.each_char do |ch|
          if escaped
            escaped = false
            next
          end
          if ch == '\\'
            escaped = true
          elsif ch == '?'
            count += 1
          end
        end
        count
      end

      # Escape a raw string for inclusion inside double quotes.
      # @param str [String]
      # @return [String]
      def escape_string(str)
        str.gsub('\\', '\\\\').gsub('"', '\\"')
      end

      # @api private
      def array_like?(value)
        value.is_a?(Array)
      end
    end
  end
end
