# frozen_string_literal: true

module SearchEngine
  module AST
    # Boolean conjunction over one or more child nodes.
    class And < Node
      attr_reader :children

      def initialize(*nodes)
        super()
        normalized = normalize(nodes)
        raise ArgumentError, 'and_ requires at least one child node' if normalized.empty?

        @children = deep_freeze_array(normalized)
        freeze
      end

      def type = :and

      def to_s
        "and(#{children.map(&:to_s).join(', ')})"
      end

      protected

      def equality_key
        [:and, @children]
      end

      def inspect_payload
        inner = children.map(&:to_s).join(', ')
        truncate_for_inspect(inner)
      end

      private

      def normalize(nodes)
        flat = []
        Array(nodes).flatten.compact.each do |n|
          next unless n.is_a?(Node)

          if n.is_a?(And)
            flat.concat(n.children)
          else
            flat << n
          end
        end
        flat
      end
    end
  end
end
