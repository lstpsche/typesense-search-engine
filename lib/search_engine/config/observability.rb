# frozen_string_literal: true

module SearchEngine
  class Config
    # Observability and structured logging configuration.
    class Observability
      # @return [Boolean] enable the compact logging subscriber automatically
      attr_accessor :enabled
      # @return [Symbol] :kv or :json
      attr_accessor :log_format
      # @return [Integer] maximum message length for error samples in logs
      attr_accessor :max_message_length
      # @return [Boolean] include short error messages in logs for batch/stale events
      attr_accessor :include_error_messages
      # @return [Boolean] also emit legacy event aliases where applicable
      attr_accessor :emit_legacy_event_aliases

      def initialize
        @enabled = true
        @log_format = :kv
        @max_message_length = 200
        @include_error_messages = false
        @emit_legacy_event_aliases = true
      end
    end
  end
end
