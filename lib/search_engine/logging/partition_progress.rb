# frozen_string_literal: true

module SearchEngine
  module Logging
    # Shared helpers for rendering standardized partition progress log lines.
    #
    # Produces the same compact line used during regular indexation and cascade
    # flows to keep output consistent and DRY.
    module PartitionProgress
      module_function

      # Build a compact log line for a finished partition import.
      #
      # @param partition [Object] opaque partition token
      # @param summary [SearchEngine::Indexer::Summary] result of the import
      # @return [String]
      def line(partition, summary)
        sample_err = extract_sample_error(summary)

        parts = []
        parts << "  partition=#{partition.inspect} → status=#{summary.status}"
        parts << "docs=#{summary.docs_total}"
        parts << "failed=#{summary.failed_total}"
        parts << "batches=#{summary.batches_total}"
        parts << "duration_ms=#{summary.duration_ms_total}"
        parts << "sample_error=#{sample_err.inspect}" if sample_err
        parts.join(' ')
      end

      # Extract one sample error message from the summary, if present.
      # Delegates to the internal helper on {SearchEngine::Base}.
      #
      # @param summary [SearchEngine::Indexer::Summary]
      # @return [String, nil]
      def extract_sample_error(summary)
        SearchEngine::Base.__se_extract_sample_error(summary)
      rescue StandardError
        nil
      end
    end
  end
end
