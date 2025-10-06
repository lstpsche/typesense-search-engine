# frozen_string_literal: true

module SearchEngine
  module AST
    # Binary comparison: field != value
    class NotEq < BinaryOp
      def type = :not_eq

      # Preserve public API
      def value = @right
    end
  end
end
