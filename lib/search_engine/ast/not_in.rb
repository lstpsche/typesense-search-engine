# frozen_string_literal: true

module SearchEngine
  module AST
    # Membership: field NOT IN values
    class NotIn < Node
      attr_reader :field, :values

      def initialize(field, values)
        super()
        @field = validate_field!(field)
        ensure_non_empty_array!(values)
        @values = deep_freeze_array(values)
        freeze
      end

      def type = :not_in

      def left = @field
      def right = @values

      def children
        [@field, @values].freeze
      end

      def to_s
        "not_in(#{format_field(@field)}, #{format_debug_value(@values)})"
      end

      protected

      def equality_key
        [:not_in, @field, @values]
      end

      def inspect_payload
        "field=#{format_field(@field)} values=#{truncate_for_inspect(format_debug_value(@values))}"
      end
    end
  end
end
