# frozen_string_literal: true

module SearchEngine
  module AST
    # Pattern: field has string prefix
    class Prefix < Node
      attr_reader :field, :prefix

      def initialize(field, prefix)
        super()
        @field = validate_field!(field)
        @prefix = validate_prefix!(prefix)
        freeze
      end

      def type = :prefix

      def left = @field
      def right = @prefix

      def children
        [@field, @prefix].freeze
      end

      def to_s
        "prefix(#{format_field(@field)}, #{format_debug_value(@prefix)})"
      end

      protected

      def equality_key
        [:prefix, @field, @prefix]
      end

      def inspect_payload
        "field=#{format_field(@field)} prefix=#{truncate_for_inspect(format_debug_value(@prefix))}"
      end

      private

      def validate_prefix!(value)
        raise ArgumentError, 'prefix must be a String' unless value.is_a?(String)

        str = value.strip
        raise ArgumentError, 'prefix cannot be blank' if str.empty?

        str.freeze
      end
    end
  end
end
