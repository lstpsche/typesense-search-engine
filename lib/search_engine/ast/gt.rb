# frozen_string_literal: true

module SearchEngine
  module AST
    # Binary comparison: field > value
    class Gt < BinaryOp
      def type = :gt

      def value = @right
    end
  end
end
