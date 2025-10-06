# frozen_string_literal: true

module SearchEngine
  module AST
    # Binary comparison: field == value
    # @!attribute [r] field
    #   @return [String]
    # @!attribute [r] value
    #   @return [Object]
    class Eq < BinaryOp
      # @return [Symbol]
      def type = :eq

      # Right-hand side reader preserved for public API
      # @return [Object]
      def value = @right
    end
  end
end
