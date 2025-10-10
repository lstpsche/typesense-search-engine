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

      # Quote a scalar Ruby value for Typesense filters with conditional quoting for strings.
      #
      # Rules (based on Typesense filter_by syntax):
      # - Strings that match a safe token pattern (e.g., Active, ACTIVE_1, foo-bar) are emitted bare
      # - Reserved words true/false/null remain bare only when actually booleans/nil; string forms are quoted
      # - Strings with any other characters are double-quoted with escaping
      # - Arrays are delegated to +quote+ to preserve element quoting rules
      #
      # @param value [Object]
      # @return [String]
      def quote_scalar_for_filter(value)
        return quote(value) if value.is_a?(Array)

        case value
        when NilClass
          'null'
        when TrueClass
          'true'
        when FalseClass
          'false'
        when Numeric
          value.to_s
        when String, Symbol
          str = value.to_s
          lc = str.strip.downcase
          # Avoid ambiguity with special literals when user passes them as strings
          return %("#{escape_string(str)}") if %w[true false null].include?(lc)

          if safe_bare_string?(str)
            str
          else
            %("#{escape_string(str)}")
          end
        when Time
          %("#{value.iso8601}")
        when DateTime
          %("#{value.iso8601}")
        when Date
          %("#{value.iso8601}")
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
            "#{field}:=#{quote_scalar_for_filter(raw)}"
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
          val = args[idx]
          val.is_a?(Array) ? quote(val) : quote_scalar_for_filter(val)
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

      # Determine whether a string can be emitted bare without quotes in filter_by.
      # Safe if it matches: starts with a letter or underscore; then letters/digits/underscore/hyphen.
      # This avoids ambiguity with numbers/booleans/null and special characters.
      def safe_bare_string?(str)
        return false if str.nil? || str.empty?

        # Disallow surrounding/backtick/dquote characters quickly
        return false if str.include?('"') || str.include?('`') || str.include?(',') || str.include?(' ')

        # Must start with a letter or underscore; subsequent chars may include digits or hyphens/underscores
        !!(str =~ /^[A-Za-z_][A-Za-z0-9_-]*$/)
      end

      # @api private
      def array_like?(value)
        value.is_a?(Array)
      end
    end
  end
end
