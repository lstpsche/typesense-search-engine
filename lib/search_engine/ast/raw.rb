# frozen_string_literal: true

module SearchEngine
  module AST
    # Escape hatch: raw string fragment passed through by compiler.
    class Raw < Node
      attr_reader :fragment

      def initialize(fragment)
        super()
        raise ArgumentError, 'fragment must be a String' unless fragment.is_a?(String)

        str = fragment.strip
        raise ArgumentError, 'fragment cannot be blank' if str.empty?

        @fragment = str.freeze
        freeze
      end

      def type = :raw

      def children
        EMPTY_ARRAY
      end

      def to_s
        "raw(#{truncate_for_inspect(@fragment)})"
      end

      protected

      def equality_key
        [:raw, @fragment]
      end

      def inspect_payload
        truncate_for_inspect(@fragment)
      end
    end
  end
end
