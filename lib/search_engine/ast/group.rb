# frozen_string_literal: true

module SearchEngine
  module AST
    # Grouping wrapper to preserve explicit precedence.
    class Group < UnaryOp
      def type = :group

      # Preserve original error message semantics by revalidating child kind
      def initialize(child)
        # Original message: 'group requires a Node child'
        raise ArgumentError, 'group requires a Node child' unless child.is_a?(Node)

        super
      end
    end
  end
end
