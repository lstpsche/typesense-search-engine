# frozen_string_literal: true

module SearchEngine
  class Config
    # Selection/hydration configuration.
    # Controls strictness of missing attributes during hydration.
    class Selection
      # @return [Boolean] when true, missing requested fields raise MissingField
      attr_accessor :strict_missing

      def initialize
        @strict_missing = false
      end
    end
  end
end
