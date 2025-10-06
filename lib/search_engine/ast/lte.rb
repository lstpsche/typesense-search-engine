# frozen_string_literal: true

module SearchEngine
  module AST
    # Binary comparison: field <= value
    class Lte < BinaryOp
      def type = :lte

      def value = @right
    end
  end
end
