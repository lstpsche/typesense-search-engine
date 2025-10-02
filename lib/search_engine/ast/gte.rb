# frozen_string_literal: true

module SearchEngine
  module AST
    # Binary comparison: field >= value
    class Gte < Node
      attr_reader :field, :value

      def initialize(field, value)
        super()
        @field = validate_field!(field)
        @value = deep_freeze_value(value)
        freeze
      end

      def type = :gte

      def left = @field
      def right = @value

      def children
        [@field, @value].freeze
      end

      def to_s
        "gte(#{format_field(@field)}, #{format_debug_value(@value)})"
      end

      protected

      def equality_key
        [:gte, @field, @value]
      end

      def inspect_payload
        "field=#{format_field(@field)} value=#{truncate_for_inspect(format_debug_value(@value))}"
      end
    end
  end
end
