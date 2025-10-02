# frozen_string_literal: true

module SearchEngine
  module AST
    # Binary comparison: field == value
    # @!attribute [r] field
    #   @return [String]
    # @!attribute [r] value
    #   @return [Object]
    class Eq < Node
      attr_reader :field, :value

      def initialize(field, value)
        super()
        @field = validate_field!(field)
        @value = deep_freeze_value(value)
        freeze
      end

      # @return [Symbol]
      def type = :eq

      # Left operand (field)
      # @return [String]
      def left = @field

      # Right operand (value)
      # @return [Object]
      def right = @value

      # @return [Array]
      def children
        [@field, @value].freeze
      end

      def to_s
        "eq(#{format_field(@field)}, #{format_debug_value(@value)})"
      end

      protected

      def equality_key
        [:eq, @field, @value]
      end

      def inspect_payload
        "field=#{format_field(@field)} value=#{truncate_for_inspect(format_debug_value(@value))}"
      end
    end
  end
end
