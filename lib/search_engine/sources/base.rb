# frozen_string_literal: true

module SearchEngine
  module Sources
    # Internal helpers shared by source adapters.
    #
    # Provides small utilities for instrumentation and for returning
    # an Enumerator when a block is not supplied.
    module Base
      private

      def monotonic_ms
        SearchEngine::Instrumentation.monotonic_ms
      end

      def instrument_batch_fetched(source:, batch_index:, rows_count:, duration_ms:, partition: nil, cursor: nil,
                                   adapter_options: {})
        return unless defined?(ActiveSupport::Notifications)

        payload = {
          source: source,
          batch_index: batch_index,
          rows_count: rows_count,
          duration_ms: duration_ms
        }
        payload[:partition] = partition unless partition.nil?
        payload[:cursor] = cursor unless cursor.nil?
        if defined?(SearchEngine::Observability)
          payload[:adapter_options] = SearchEngine::Observability.redact(adapter_options)
        end
        SearchEngine::Instrumentation.instrument('search_engine.source.batch_fetched', payload) {}
      end

      def instrument_error(source:, error:, partition: nil, cursor: nil, adapter_options: {})
        return unless defined?(ActiveSupport::Notifications)

        payload = {
          source: source,
          error_class: error.class.name,
          message: error.message.to_s[0, 200]
        }
        payload[:partition] = partition unless partition.nil?
        payload[:cursor] = cursor unless cursor.nil?
        if defined?(SearchEngine::Observability)
          payload[:adapter_options] = SearchEngine::Observability.redact(adapter_options)
        end
        if error.respond_to?(:to_h)
          h = error.to_h
          payload[:error_hint] = h[:hint] if h[:hint]
          payload[:error_doc] = h[:doc] if h[:doc]
        end
        SearchEngine::Instrumentation.instrument('search_engine.source.error', payload) {}
      end

      def enum_for_each_batch(partition:, cursor:)
        return to_enum(:each_batch, partition: partition, cursor: cursor) unless block_given?

        yield
      end
    end
  end
end
