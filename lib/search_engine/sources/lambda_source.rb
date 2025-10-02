# frozen_string_literal: true

module SearchEngine
  module Sources
    # Lambda-backed source adapter that delegates batching to a provided callable.
    #
    # The callable must accept keyword args `cursor:` and `partition:` and return an
    # Enumerator that yields arrays of records. This adapter validates the contract
    # and emits instrumentation per yielded batch.
    class LambdaSource
      include Base

      # @param callable [#call] object responding to call(cursor:, partition:)
      def initialize(callable)
        unless callable.respond_to?(:call)
          raise SearchEngine::Errors::InvalidParams, 'LambdaSource requires a callable that responds to #call'
        end

        @callable = callable
      end

      # Iterate over batches from the provided callable.
      # @param partition [Object, nil]
      # @param cursor [Object, nil]
      # @yieldparam rows [Array<Object>]
      # @return [Enumerator] when no block is given
      def each_batch(partition: nil, cursor: nil)
        return enum_for(:each_batch, partition: partition, cursor: cursor) unless block_given?

        enum = @callable.call(cursor: cursor, partition: partition)
        unless enum.respond_to?(:each)
          raise SearchEngine::Errors::InvalidParams, 'LambdaSource callable must return an Enumerator-like object'
        end

        idx = 0
        started = monotonic_ms
        enum.each do |rows|
          raise SearchEngine::Errors::InvalidParams, 'LambdaSource must yield arrays of rows' unless rows.is_a?(Array)

          duration = monotonic_ms - started
          instrument_batch_fetched(source: 'lambda', batch_index: idx, rows_count: rows.size, duration_ms: duration,
                                   partition: partition, cursor: cursor, adapter_options: {}
          )
          yield rows
          idx += 1
          started = monotonic_ms
        end
      rescue StandardError => error
        instrument_error(source: 'lambda', error: error, partition: partition, cursor: cursor, adapter_options: {})
        raise
      end
    end
  end
end
