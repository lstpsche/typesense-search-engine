# frozen_string_literal: true

module SearchEngine
  module AST
    # Binary comparison: field < value
    class Lt < BinaryOp
      def type = :lt

      def value = @right
    end
  end
end
