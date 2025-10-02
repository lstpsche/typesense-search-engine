# frozen_string_literal: true

require 'json'

module SearchEngine
  # Batch importer for streaming JSONL documents into a physical collection.
  #
  # Emits one AS::Notifications event per attempt: "search_engine.indexer.batch_import".
  # Works strictly batch-by-batch to avoid memory growth and retries transient
  # failures with exponential backoff and jitter.
  class Indexer
    # Aggregated summary of an import run.
    Summary = Struct.new(
      :collection,
      :status,
      :batches_total,
      :docs_total,
      :success_total,
      :failed_total,
      :duration_ms_total,
      :batches,
      keyword_init: true
    )

    # Import pre-batched documents using JSONL bulk import.
    #
    # @param klass [Class] a SearchEngine::Base subclass (reserved for future mappers)
    # @param into [String] target physical collection name
    # @param enum [Enumerable] yields batches (Array-like) of Hash documents
    # @param batch_size [Integer, nil] soft guard only; not used unless 413 handling
    # @param action [Symbol] :upsert (default), :create, or :update
    # @return [Summary]
    # @raise [SearchEngine::Errors::InvalidParams]
    def self.import!(klass, into:, enum:, batch_size: nil, action: :upsert)
      raise Errors::InvalidParams, 'klass must be a Class' unless klass.is_a?(Class)
      unless into.is_a?(String) && !into.strip.empty?
        raise Errors::InvalidParams, 'into must be a non-empty String (physical collection name)'
      end
      raise Errors::InvalidParams, 'enum must be an Enumerable' unless enum.respond_to?(:each)

      allowed_actions = %i[upsert create update]
      act = action.to_sym
      unless allowed_actions.include?(act)
        raise Errors::InvalidParams, "action must be one of #{allowed_actions.inspect}"
      end

      cfg = SearchEngine.config.indexer
      _effective_batch_size = (batch_size || cfg&.batch_size || 2000).to_i

      client = SearchEngine::Client.new
      started_ms = monotonic_ms
      batches_stats = []
      docs_total = 0
      success_total = 0
      failed_total = 0
      call_index = 0
      next_index = -> { call_index += 1 }

      enum.each do |batch|
        docs = to_array(batch)
        stats_list = import_batch_with_handling(client, into, docs, act, next_index)
        stats_list.each do |s|
          batches_stats << s
          docs_total += s[:docs_count]
          success_total += s[:success_count]
          failed_total += s[:failure_count]
        end
      end

      duration = monotonic_ms - started_ms
      status = if failed_total.zero?
                 :ok
               elsif success_total.positive?
                 :partial
               else
                 :failed
               end

      Summary.new(
        collection: into,
        status: status,
        batches_total: batches_stats.size,
        docs_total: docs_total,
        success_total: success_total,
        failed_total: failed_total,
        duration_ms_total: duration.round(1),
        batches: batches_stats
      )
    end

    # Build JSONL for the first batch without HTTP.
    # @return [Hash] { collection, action, bytes_estimate, docs_count, sample_line }
    def self.dry_run!(_klass, into:, enum:, _batch_size: nil, action: :upsert)
      raise Errors::InvalidParams, 'enum must be an Enumerable' unless enum.respond_to?(:each)

      first_batch = enum.respond_to?(:first) ? enum.first : nil
      first_batch = to_array(first_batch) if first_batch
      first_batch ||= []

      buffer = +''
      docs_count = encode_jsonl!(first_batch, buffer)
      sample_line = buffer.lines.first&.strip

      {
        collection: into.to_s,
        action: action.to_sym,
        bytes_estimate: buffer.bytesize,
        docs_count: docs_count,
        sample_line: sample_line
      }
    end

    class << self
      private

      def import_batch_with_handling(client, collection, docs, action, next_index)
        buffer = +''
        docs_count = encode_jsonl!(docs, buffer)
        bytes_sent = buffer.bytesize
        idx = next_index.call

        begin
          attempt_stats = with_retries do |attempt|
            perform_attempt(client, collection, action, buffer, docs_count, bytes_sent, idx, attempt)
          end
          [attempt_stats]
        rescue Errors::Api => error
          if error.status.to_i == 413 && docs.size > 1
            mid = docs.size / 2
            left = docs[0...mid]
            right = docs[mid..]
            import_batch_with_handling(client, collection, left, action, next_index) +
              import_batch_with_handling(client, collection, right, action, next_index)
          else
            [
              {
                index: idx,
                docs_count: docs_count,
                success_count: 0,
                failure_count: docs_count,
                attempts: 1,
                http_status: error.status.to_i,
                duration_ms: 0.0,
                bytes_sent: bytes_sent,
                errors_sample: [safe_error_excerpt(error)]
              }
            ]
          end
        end
      end

      def perform_attempt(client, collection, action, jsonl, docs_count, bytes_sent, idx, attempt)
        start = monotonic_ms
        success_count = 0
        failure_count = 0
        http_status = 200
        error_sample = []

        if defined?(ActiveSupport::Notifications)
          se_payload = {
            collection: collection,
            batch_index: idx,
            docs_count: docs_count,
            success_count: nil,
            failure_count: nil,
            attempts: attempt,
            http_status: nil,
            bytes_sent: bytes_sent,
            transient_retry: attempt > 1,
            retry_after_s: nil,
            error_sample: nil
          }
          ActiveSupport::Notifications.instrument('search_engine.indexer.batch_import', se_payload) do
            raw = client.import_documents(collection: collection, jsonl: jsonl, action: action)
            success_count, failure_count, error_sample = parse_import_response(raw)
            http_status = 200
            se_payload[:success_count] = success_count
            se_payload[:failure_count] = failure_count
            se_payload[:http_status] = http_status
          rescue Errors::Api => error
            se_payload[:success_count] = 0
            se_payload[:failure_count] = docs_count
            se_payload[:http_status] = error.status.to_i
            se_payload[:error_sample] = [safe_error_excerpt(error)]
            raise
          end
        else
          raw = client.import_documents(collection: collection, jsonl: jsonl, action: action)
          success_count, failure_count, error_sample = parse_import_response(raw)
        end

        duration = monotonic_ms - start
        {
          index: idx,
          docs_count: docs_count,
          success_count: success_count,
          failure_count: failure_count,
          attempts: attempt,
          http_status: http_status,
          duration_ms: duration.round(1),
          bytes_sent: bytes_sent,
          errors_sample: error_sample
        }
      end

      def with_retries
        cfg = SearchEngine.config.indexer
        attempts = cfg&.retries && cfg.retries[:attempts].to_i.positive? ? cfg.retries[:attempts].to_i : 3
        base = cfg&.retries && cfg.retries[:base].to_f.positive? ? cfg.retries[:base].to_f : 0.5
        max = cfg&.retries && cfg.retries[:max].to_f.positive? ? cfg.retries[:max].to_f : 5.0
        jitter = cfg&.retries && cfg.retries[:jitter_fraction].to_f >= 0 ? cfg.retries[:jitter_fraction].to_f : 0.2

        (1..attempts).each do |i|
          return yield(i)
        rescue Errors::Timeout, Errors::Connection
          raise if i >= attempts

          sleep_with_backoff(i, base: base, max: max, jitter_fraction: jitter)
        rescue Errors::Api => error
          code = error.status.to_i
          raise unless transient_status?(code)
          raise if i >= attempts

          sleep_with_backoff(i, base: base, max: max, jitter_fraction: jitter)
        end
      end

      def sleep_with_backoff(attempt, base:, max:, jitter_fraction:)
        exp = [base * (2 ** (attempt - 1)), max].min
        jitter = exp * jitter_fraction
        delta = rand(-jitter..jitter)
        sleep_time = exp + delta
        sleep(sleep_time) if sleep_time.positive?
      end

      def transient_status?(code)
        return true if code == 429
        return true if code >= 500 && code <= 599

        false
      end

      def to_array(batch)
        return batch if batch.is_a?(Array)

        batch.respond_to?(:to_a) ? batch.to_a : Array(batch)
      end

      def encode_jsonl!(docs, buffer)
        count = 0
        buffer.clear
        docs.each do |raw|
          doc = ensure_hash_document(raw)
          ensure_id!(doc)
          buffer << JSON.generate(doc)
          buffer << "\n" if count < (docs.size - 1)
          count += 1
        end
        count
      end

      def ensure_hash_document(obj)
        if obj.is_a?(Hash)
          obj
        else
          raise Errors::InvalidParams,
                'Indexer requires batches of Hash-like documents with at least an :id key. ' \
                'Mapping DSL is not available yet. See docs/indexer.md.'
        end
      end

      def ensure_id!(doc)
        has_id = doc.key?(:id) || doc.key?('id')
        raise Errors::InvalidParams, 'document is missing required id' unless has_id
      end

      def parse_import_response(raw)
        return parse_from_string(raw) if raw.is_a?(String)
        return parse_from_array(raw) if raw.is_a?(Array)

        [0, 0, []]
      end

      def parse_from_string(str)
        success = 0
        failure = 0
        samples = []

        str.each_line do |line|
          line = line.strip
          next if line.empty?

          h = safe_parse_json(line)
          unless h
            failure += 1
            samples << 'invalid-json-line'
            next
          end

          if truthy?(h['success'] || h[:success])
            success += 1
          else
            failure += 1
            msg = h['error'] || h[:error] || h['message'] || h[:message]
            samples << msg.to_s[0, 200] if msg
          end
        end

        [success, failure, samples[0, 5]]
      end

      def parse_from_array(arr)
        success = 0
        failure = 0
        samples = []

        arr.each do |h|
          if h.is_a?(Hash) && truthy?(h['success'] || h[:success])
            success += 1
          else
            failure += 1
            msg = h.is_a?(Hash) ? (h['error'] || h[:error] || h['message'] || h[:message]) : nil
            samples << msg.to_s[0, 200] if msg
          end
        end

        [success, failure, samples[0, 5]]
      end

      def safe_parse_json(line)
        JSON.parse(line)
      rescue StandardError
        nil
      end

      def truthy?(val)
        val == true || val.to_s.downcase == 'true'
      end

      def safe_error_excerpt(error)
        cls = error.class.name
        msg = error.message.to_s
        "#{cls}: #{msg[0, 200]}"
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      end
    end
  end
end
