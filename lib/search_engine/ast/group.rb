# frozen_string_literal: true

module SearchEngine
  module AST
    # Grouping wrapper to preserve explicit precedence.
    class Group < Node
      attr_reader :child

      def initialize(child)
        super()
        raise ArgumentError, 'group requires a Node child' unless child.is_a?(Node)

        @child = child
        freeze
      end

      def type = :group

      def children
        [@child].freeze
      end

      def to_s
        "group(#{@child})"
      end

      protected

      def equality_key
        [:group, @child]
      end

      def inspect_payload
        @child.to_s
      end
    end
  end
end
