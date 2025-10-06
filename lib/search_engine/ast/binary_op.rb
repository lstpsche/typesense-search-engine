# frozen_string_literal: true

module SearchEngine
  module AST
    # Base class for simple binary operator nodes with a field on the left
    # and a literal payload on the right.
    #
    # Subclasses must implement #type and can override hooks to customize
    # right-hand normalization and inspect key naming.
    #
    # Responsibilities:
    # - Validate and store field
    # - Normalize and freeze right-hand side via #normalize_right
    # - Provide common children/left/right accessors
    # - Provide consistent #to_s and #inspect payloads
    class BinaryOp < Node
      # @return [String]
      attr_reader :field
      # @return [Object]
      attr_reader :right

      # @param field [String, Symbol]
      # @param right [Object]
      def initialize(field, right)
        super()
        @field = validate_field!(field)
        @right = normalize_right(right)
        freeze
      end

      # Left operand (field)
      # @return [String]
      def left = @field

      # @return [Array]
      def children
        [@field, @right].freeze
      end

      # String representation with unquoted field and formatted right value
      # @return [String]
      def to_s
        "#{type}(#{format_field(@field)}, #{format_debug_value(@right)})"
      end

      protected

      # Default normalization for right-hand side: deep-freeze supported values
      # @param value [Object]
      # @return [Object]
      def normalize_right(value)
        deep_freeze_value(value)
      end

      # Key name for right-hand side in #inspect payload (e.g., "value", "values")
      # @return [String]
      def inspect_right_kv_key
        'value'
      end

      # Equality uses structural tuple of [type, field, right]
      # @return [Array]
      def equality_key
        [type, @field, @right]
      end

      # Compact inspect payload shared by binary operators
      # @return [String]
      def inspect_payload
        rhs = truncate_for_inspect(format_debug_value(@right))
        "field=#{format_field(@field)} #{inspect_right_kv_key}=#{rhs}"
      end
    end
  end
end
