# frozen_string_literal: true

module SearchEngine
  module AST
    # Binary comparison: field != value
    class NotEq < BinaryOp
      attr_reader :field

      def type = :not_eq

      # Preserve public API
      def value = @right
    end
  end
end
