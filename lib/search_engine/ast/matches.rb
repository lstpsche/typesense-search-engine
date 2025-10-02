# frozen_string_literal: true

module SearchEngine
  module AST
    # Pattern: field matches pattern (regex-like). Stores pattern source only.
    class Matches < Node
      attr_reader :field, :pattern

      def initialize(field, pattern)
        super()
        @field = validate_field!(field)
        @pattern = validate_pattern!(pattern)
        freeze
      end

      def type = :matches

      def left = @field
      def right = @pattern

      def children
        [@field, @pattern].freeze
      end

      def to_s
        "matches(#{format_field(@field)}, /#{@pattern}/)"
      end

      protected

      def equality_key
        [:matches, @field, @pattern]
      end

      def inspect_payload
        "field=#{format_field(@field)} pattern=#{truncate_for_inspect(@pattern)}"
      end

      private

      def validate_pattern!(pattern)
        str = case pattern
              when Regexp then pattern.source
              when String then pattern.dup
              else
                raise ArgumentError, 'pattern must be a String or Regexp'
              end
        str = str.strip
        raise ArgumentError, 'pattern cannot be blank' if str.empty?

        str.freeze
      end
    end
  end
end
