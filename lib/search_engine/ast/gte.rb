# frozen_string_literal: true

module SearchEngine
  module AST
    # Binary comparison: field >= value
    class Gte < BinaryOp
      def type = :gte

      def value = @right
    end
  end
end
