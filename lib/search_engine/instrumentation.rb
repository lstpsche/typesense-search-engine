# frozen_string_literal: true

module SearchEngine
  # Lightweight wrapper over ActiveSupport::Notifications that standardizes
  # event names, payload shaping, and timing helpers. Provides a thread-local
  # context to propagate dispatch metadata (e.g., mode, job_id) from the
  # dispatcher/job into lower layers such as the indexer.
  #
  # Public API is intentionally small:
  # - {.instrument(event, payload = {}) { }}: emit an event (no-op without AS::N)
  # - {.time(event, base_payload = {}) { |payload| }}: measure duration_ms
  # - {.with_context(hash) { }}: set per-thread context for nested calls
  # - {.context}: current shallow context Hash (dup)
  #
  # All payloads are duped, nil values are pruned, and keys are symbolized.
  module Instrumentation
    THREAD_KEY = :__search_engine_context__

    # Emit an event with a shaped payload.
    # @param event [String] canonical event name (e.g., "search_engine.schema.diff")
    # @param payload [Hash] small, JSON-safe payload
    # @yield optional block to wrap duration for framework semantics
    # @return [void]
    def self.instrument(event, payload = {})
      return unless defined?(ActiveSupport::Notifications)

      shaped = shape_payload(payload)
      ActiveSupport::Notifications.instrument(event, shaped) { yield if block_given? }
    end

    # Known events
    #
    # - "search_engine.joins.compile": emitted once per relation compile summarizing JOIN usage.
    #   Payload keys (nil/empty omitted):
    #   - :collection [String]
    #   - :join_count [Integer]
    #   - :assocs [Array<String>]
    #   - :used_in [Hash{Symbol=>Array<String>}] include/filter/sort association usage
    #   - :include_len [Integer]
    #   - :filter_len [Integer]
    #   - :sort_len [Integer]
    #   - :duration_ms [Float]
    #   - :has_joins [Boolean]
    # - "search_engine.selection.compile": emitted once per relation compile summarizing field selection counts.
    #   Payload keys:
    #   - :include_count [Integer] total effective include fields (root + nested after precedence)
    #   - :exclude_count [Integer] total excluded fields (root + nested)
    #   - :nested_assoc_count [Integer] associations with any selection state (include or exclude)
    # - "search_engine.preset.apply": emitted once per relation compile when a preset is present.
    #   Payload keys (keys-only; values redacted elsewhere):
    #   - :preset_name [String] effective namespaced preset
    #   - :mode [Symbol] one of :merge, :only, :lock
    #   - :locked_domains [Array<Symbol>] configured locked domains for :lock mode
    #   - :pruned_keys [Array<Symbol>] keys removed by the chosen mode
    # - "search_engine.curation.compile": emitted once per relation compile when curation state is present.
    #   Payload keys:
    #   - :pinned_count [Integer]
    #   - :hidden_count [Integer]
    #   - :has_override_tags [Boolean]
    #   - :filter_curated_hits [true,false,nil]
    # - "search_engine.curation.conflict": emitted when overlaps or limits are detected; at most once per compile.
    #   Payload keys:
    #   - :type [Symbol] one of :overlap, :limit_exceeded
    #   - :count [Integer]
    #   - :limit [Integer, optional] present when type==:limit_exceeded
    #   # See also: docs/presets.md#observability
    # Measure a block and attach duration_ms to payload.
    # @param event [String]
    # @param base_payload [Hash]
    # @yieldreturn [Object] result of the block
    # @return [Object]
    def self.time(event, base_payload = {})
      started = monotonic_ms
      result = nil
      instrument(event, base_payload.merge(started_at_ms: started)) do
        result = yield(base_payload)
      end
      result

      # NOTE: ActiveSupport::Notifications already attaches duration; callers
      # should prefer event.duration on the subscriber side. We still provide
      # started_at_ms in the payload for completeness.
    end

    # Set a shallow thread-local context for nested calls.
    # @param ctx [Hash]
    # @yield block executed with context applied
    # @return [Object] result of the block
    def self.with_context(ctx)
      prev = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = (prev || {}).merge(ctx || {})
      yield
    ensure
      Thread.current[THREAD_KEY] = prev
    end

    # Current shallow context hash.
    # @return [Hash]
    def self.context
      (Thread.current[THREAD_KEY] || {}).dup
    end

    # Monotonic clock in milliseconds.
    # @return [Float]
    def self.monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    end

    # Internal: normalize and prune a payload hash.
    def self.shape_payload(payload)
      shaped = {}
      (payload || {}).each do |k, v|
        next if v.nil?

        shaped[k.to_sym] = v
      end
      # Attach current context values without overriding explicit keys
      ctx = context
      ctx.each do |k, v|
        shaped[k] = v unless shaped.key?(k)
      end
      shaped
    end
    private_class_method :shape_payload
  end
end
