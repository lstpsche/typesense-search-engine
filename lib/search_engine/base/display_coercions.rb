# frozen_string_literal: true

require 'active_support/concern'

module SearchEngine
  class Base
    # Internal helpers for coercing values for display/formatting.
    #
    # This concern provides shared instance-level utilities used by
    # hydration and pretty-printing. No business logic changes.
    module DisplayCoercions
      extend ActiveSupport::Concern

      private

      # Convert integer epoch seconds to a Time in the current zone for display.
      # Falls back gracefully when value is not an Integer.
      def __se_coerce_doc_updated_at_for_display(value)
        int_val = begin
          Integer(value)
        rescue StandardError
          nil
        end
        return value if int_val.nil?

        if defined?(Time) && defined?(Time.zone) && Time.zone
          Time.zone.at(int_val)
        else
          Time.at(int_val)
        end
      rescue StandardError
        value
      end
    end
  end
end
