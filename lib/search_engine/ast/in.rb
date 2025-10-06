# frozen_string_literal: true

module SearchEngine
  module AST
    # Membership: field IN values
    # @!attribute [r] field
    #   @return [String]
    # @!attribute [r] values
    #   @return [Array]
    class In < BinaryOp
      def type = :in

      # Preserve public API name
      def values = @right

      protected

      def normalize_right(values)
        ensure_non_empty_array!(values)
        deep_freeze_array(values)
      end

      def inspect_right_kv_key
        'values'
      end
    end
  end
end
