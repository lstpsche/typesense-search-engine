# frozen_string_literal: true

module SearchEngine
  module AST
    # Base class for unary operator nodes with a single Node child.
    #
    # Subclasses must implement #type. This base validates the child is a Node,
    # provides the common children list, and stable equality/inspect logic.
    class UnaryOp < Node
      # @return [SearchEngine::AST::Node]
      attr_reader :child

      # @param child [SearchEngine::AST::Node]
      def initialize(child)
        super()
        raise ArgumentError, 'child must be a SearchEngine::AST::Node' unless child.is_a?(Node)

        @child = child
        freeze
      end

      # @return [Array<SearchEngine::AST::Node>]
      def children
        [@child].freeze
      end

      # @return [String]
      def to_s
        "#{type}(#{@child})"
      end

      protected

      def equality_key
        [type, @child]
      end

      def inspect_payload
        @child.to_s
      end
    end
  end
end
