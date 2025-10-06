# frozen_string_literal: true

module SearchEngine
  module AST
    # Binary comparison: field < value
    class Lt < BinaryOp
      attr_reader :field

      def type = :lt

      def value = @right
    end
  end
end
