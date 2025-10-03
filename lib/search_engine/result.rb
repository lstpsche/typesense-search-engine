# frozen_string_literal: true

module SearchEngine
  # Result wraps a Typesense search response and exposes hydrated hits.
  #
  # Hydration converts each hit's document into either an instance of the
  # provided model class or a generic OpenStruct when no class is available.
  #
  # - Enumeration yields hydrated objects (includes Enumerable)
  # - Metadata readers: {#found}, {#out_of}, {#facets}, {#raw}
  # - Selection is respected implicitly by hydrating only keys present in the
  #   returned document; no missing attributes are synthesized.
  #
  # Unknown collections: when +klass+ is +nil+, hydration falls back to
  # OpenStruct.
  class Result
    include Enumerable

    # Immutable lightweight group record for grouped responses.
    #
    # @!attribute [r] key
    #   @return [Hash{String=>Object}] mapping of field name to group value
    # @!attribute [r] hits
    #   @return [Array<Object>] hydrated hits within the group
    # @!attribute [r] size
    #   @return [Integer] number of hits in the group
    class Group
      attr_reader :key, :hits

      # @param key [Hash{String=>Object}]
      # @param hits [Array<Object>]
      def initialize(key:, hits:)
        @key = (key || {}).dup.freeze
        @hits = Array(hits).freeze
        freeze
      end

      # @return [Integer]
      def size
        @hits.size
      end

      # @return [String]
      def inspect
        "#<SearchEngine::Result::Group key=#{key.inspect} size=#{size}>"
      end

      def ==(other)
        other.is_a?(Group) && other.key == key && other.hits == hits
      end
    end

    # @return [Array<Object>] hydrated hits (frozen internal array)
    # @return [Integer] number of documents that matched the search
    # @return [Integer] number of documents searched
    # @return [Array<Hash>, nil] facet counts as returned by Typesense
    # @return [Hash] raw Typesense response (unmodified)
    attr_reader :hits, :found, :out_of, :facets, :raw

    # Build a new result wrapper.
    #
    # @param raw [Hash] Parsed Typesense response ("hits"/"grouped_hits", "found", "out_of", "facet_counts")
    # @param klass [Class, nil] Optional model class used to hydrate each document
    def initialize(raw, klass: nil)
      require 'ostruct'

      @raw   = raw || {}
      @found = @raw['found']
      @out_of = @raw['out_of']
      @facets = @raw['facet_counts']
      @klass  = klass

      @__groups_memo = nil

      if grouped?
        groups_built = build_groups
        @__groups_memo = groups_built.freeze
        first_hits = groups_built.map { |g| g.hits.first }.compact
        @hits = first_hits.freeze
        instrument_group_parse(groups_built) if defined?(SearchEngine::Instrumentation)
      else
        documents = Array(@raw['hits']).map { |h| h && h['document'] }.compact
        hydrated = documents.map { |doc| hydrate(doc) }
        @hits = hydrated.freeze
      end

      freeze
    end

    # Iterate over hydrated hits.
    # @yieldparam obj [Object] hydrated object
    # @return [Enumerator] when no block is given
    def each(&block)
      return @hits.each unless block_given?

      @hits.each(&block)
    end

    # @return [Array<Object>] a shallow copy of hydrated hits
    def to_a
      @hits.dup
    end

    # @return [Integer]
    def size
      @hits.size
    end

    # @return [Boolean]
    def empty?
      @hits.empty?
    end

    # Whether this result represents a grouped response.
    # Detection prefers presence and Array-ness of a grouped section.
    # @return [Boolean]
    def grouped?
      gh = @raw['grouped_hits'] || @raw[:grouped_hits]
      gh.is_a?(Array)
    end

    # Groups for grouped responses. Returns an empty Array when not grouped.
    # The returned Array is frozen; each Group is immutable.
    # @return [Array<SearchEngine::Result::Group>]
    def groups
      return [].freeze unless grouped?

      @__groups_memo.dup
    end

    # Enumerate over groups. Returns an Enumerator when no block given.
    # Empty enumerator when not grouped.
    # @yieldparam group [SearchEngine::Result::Group]
    # @return [Enumerator]
    def each_group(&block)
      return enum_for(:each_group) unless block_given?

      groups.each(&block)
    end

    # Number of groups present in this result page.
    # When grouping is disabled, returns 0.
    # @return [Integer]
    # @example
    #   res = SearchEngine::Product.group_by(:brand_id, limit: 1).execute
    #   res.groups_count #=> number of groups in this page
    def groups_count
      return 0 unless grouped?

      @__groups_memo.size
    end

    # Total documents found by the backend for this query (not page-limited).
    # Reads the backend-provided scalar (e.g., Typesense's `found`).
    # @return [Integer, nil]
    # @example
    #   res = SearchEngine::Product.group_by(:brand_id, limit: 1).execute
    #   res.total_found #=> total documents found
    def total_found
      @found
    end

    # Total number of groups for this query.
    # If the backend exposes a total groups count, returns that value.
    # Otherwise, falls back to the number of groups in the current page
    # (i.e., {#groups_count}). When grouping is disabled, returns +nil+.
    # @return [Integer, nil]
    # @example
    #   res = SearchEngine::Product.group_by(:brand_id, limit: 1).execute
    #   res.total_groups #=> global groups if available; else groups_count (page-scoped)
    def total_groups
      return nil unless grouped?

      api_total = detect_total_groups_from_raw(@raw)
      api_total.nil? ? @__groups_memo.size : api_total
    end

    # First group in this page or +nil+ when there are no groups.
    # Returns a reference to the memoized group; no new objects are allocated.
    # @return [SearchEngine::Result::Group, nil]
    def first_group
      return nil unless grouped?

      @__groups_memo.first
    end

    # Last group in this page or +nil+ when there are no groups.
    # Returns a reference to the memoized group; no new objects are allocated.
    # @return [SearchEngine::Result::Group, nil]
    def last_group
      return nil unless grouped?

      @__groups_memo.last
    end

    private

    # Attempt to read a total groups count from the raw payload using common keys.
    # Returns +nil+ when the backend does not provide a value.
    # @param raw [Hash]
    # @return [Integer, nil]
    def detect_total_groups_from_raw(raw)
      keys = %w[total_groups group_count groups_count found_groups total_group_count total_grouped total_group_matches]
      keys.each do |key|
        val = raw[key] || raw[key.to_sym]
        next if val.nil?
        return Integer(val) if val.is_a?(Integer) || (val.is_a?(String) && val.match?(/\A-?\d+\z/))
      end
      nil
    rescue StandardError
      nil
    end

    # Hydrate a single Typesense document (Hash) into a Ruby object.
    #
    # If +@klass+ is present, an instance of that class is allocated and each
    # document key is assigned as an instance variable on the object. No reader
    # methods are generated; callers may access via the model's own readers (if
    # defined) or via reflection. Unknown keys are permitted.
    #
    # If +@klass+ is +nil+, an OpenStruct is created with the same keys.
    #
    # @param doc [Hash]
    # @return [Object]
    def hydrate(doc)
      if @klass
        @klass.new.tap do |obj|
          doc.each do |key, value|
            obj.instance_variable_set(ivar_name(key), value)
          end
        end
      else
        OpenStruct.new(doc)
      end
    end

    # Build Group objects from the raw grouped response.
    # Preserves backend order and hydrates documents once.
    # @return [Array<SearchEngine::Result::Group>]
    def build_groups
      grouped = @raw['grouped_hits'] || @raw[:grouped_hits] || []
      fields = group_by_fields_from_raw

      grouped.map do |entry|
        key_values = Array(entry['group_key'] || entry[:group_key])
        key_hash = build_group_key_hash(fields, key_values)

        docs = Array(entry['hits'] || entry[:hits]).map { |h| h && (h['document'] || h[:document]) }.compact
        hydrated = docs.map { |doc| hydrate(doc) }

        Group.new(key: key_hash, hits: hydrated)
      end
    end

    # Derive group_by fields from echoed request params when available.
    # Returns an Array of field names (Strings). Empty when unknown.
    def group_by_fields_from_raw
      params = @raw['request_params'] || @raw[:request_params] || @raw['search_params'] || @raw[:search_params]
      return [] unless params

      gb = params['group_by'] || params[:group_by]
      return [] unless gb.is_a?(String) && !gb.strip.empty?

      gb.split(',').map { |s| s.to_s.strip }.reject(&:empty?)
    end

    # Build a Hash mapping field names to coerced group key values.
    # Falls back to a single-field synthetic key when fields are unknown.
    def build_group_key_hash(fields, values)
      return {} if values.empty?

      if fields.any?
        out = {}
        fields.each_with_index do |field, idx|
          break if idx >= values.size

          out[field.to_s] = coerce_group_value(values[idx])
        end
        return out
      end

      return { 'group' => coerce_group_value(values.first) } if values.size == 1

      out = {}
      values.each_with_index do |val, idx|
        out["group_#{idx}"] = coerce_group_value(val)
      end
      out
    end

    # Best-effort coercion for common scalar types.
    def coerce_group_value(value)
      return nil if value.nil?

      return true if value == true || value.to_s == 'true'
      return false if value == false || value.to_s == 'false'
      return Integer(value) if value.is_a?(String) && value.match?(/\A-?\d+\z/)
      return Float(value) if value.is_a?(String) && value.match?(/\A-?\d+\.\d+\z/)

      value
    end

    def ivar_name(key)
      @ivar_prefix_cache ||= {}
      @ivar_prefix_cache[key] ||= "@#{key}"
    end

    def instrument_group_parse(groups)
      count = groups.size
      total = groups.inject(0) { |acc, g| acc + g.size }
      avg = count.positive? ? (total.to_f / count) : 0.0
      coll = begin
        @klass.respond_to?(:collection) ? @klass.collection : nil
      rescue StandardError
        nil
      end

      SearchEngine::Instrumentation.instrument(
        'search_engine.result.grouped_parsed',
        collection: coll,
        groups_count: count,
        avg_group_size: avg
      )
    end
  end
end
