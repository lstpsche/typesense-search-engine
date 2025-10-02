# frozen_string_literal: true

require 'set'

module SearchEngine
  # Mapper compiles a per-collection mapping function and validates
  # mapped documents against the compiled schema.
  #
  # Public API:
  # - {SearchEngine::Mapper.for(klass)} -> compiled mapper or nil when undefined
  # - {SearchEngine::Mapper::Compiled#map_batch!(rows, batch_index:)} -> [Array<Hash>, Hash]
  module Mapper
    # Simple DSL holder used by Base#index to capture source and map block.
    class Dsl
      # @return [Hash, nil] original source definition captured from DSL
      attr_reader :source_def
      # @return [Proc, nil] mapping proc captured from DSL
      attr_reader :map_proc

      def initialize(klass)
        @klass = klass
        @source_def = nil
        @map_proc = nil
        @partitions_proc = nil
        @partition_fetch_proc = nil
        @before_partition_proc = nil
        @after_partition_proc = nil
      end

      # Declare a source adapter for this collection. Compatible with
      # SearchEngine::Sources.build signature. Stored for compatibility; the
      # mapper only requires the `map`.
      # @param type [Symbol]
      # @param options [Hash]
      # @yield for :lambda sources
      # @return [void]
      def source(type, **options, &block)
        @source_def = { type: type.to_sym, options: options, block: block }
        nil
      end

      # Define the mapping block.
      # @yield [record] yields each source record to the block
      # @yieldparam record [Object]
      # @yieldreturn [Hash, #to_h, #as_json] a document-like object
      # @return [void]
      def map(&block)
        raise ArgumentError, 'map requires a block' unless block

        @map_proc = block
        nil
      end

      # Partitioning: declare how to enumerate partitions for full rebuilds.
      # @yieldreturn [Enumerable] a list/Enumerable of opaque partition keys
      # @return [void]
      def partitions(&block)
        raise ArgumentError, 'partitions requires a block' unless block

        @partitions_proc = block
        nil
      end

      # Partitioning: provide a per-partition batch enumerator.
      # The block receives the partition key and must return an Enumerable of batches (Arrays of records).
      # @yieldparam partition [Object]
      # @yieldreturn [Enumerable<Array>] yields Arrays of records per batch
      # @return [void]
      def partition_fetch(&block)
        raise ArgumentError, 'partition_fetch requires a block' unless block

        @partition_fetch_proc = block
        nil
      end

      # Hook executed before importing a partition.
      # The block receives the partition key.
      # @yieldparam partition [Object]
      # @return [void]
      def before_partition(&block)
        raise ArgumentError, 'before_partition requires a block' unless block

        @before_partition_proc = block
        nil
      end

      # Hook executed after importing a partition.
      # The block receives the partition key.
      # @yieldparam partition [Object]
      # @return [void]
      def after_partition(&block)
        raise ArgumentError, 'after_partition requires a block' unless block

        @after_partition_proc = block
        nil
      end

      # Freeze internal state for immutability and return a definition Hash.
      # @return [Hash]
      def to_definition
        {
          source: @source_def,
          map: @map_proc,
          partitions: @partitions_proc,
          partition_fetch: @partition_fetch_proc,
          before_partition: @before_partition_proc,
          after_partition: @after_partition_proc
        }.freeze
      end
    end

    # Immutable compiled mapper for a specific collection class.
    class Compiled
      attr_reader :klass

      def initialize(klass:, map_proc:, schema_fields:, types_by_field:, options: {})
        @klass = klass
        @map_proc = map_proc
        @schema_fields = schema_fields.freeze # Array of field names (String)
        @types_by_field = types_by_field.freeze # { "field" => "int64" }
        @required_keys = @schema_fields.map(&:to_sym).to_set.freeze
        @allowed_keys = @required_keys
        @options = default_options.merge(options || {})
        freeze
      end

      # Map and validate a batch of rows.
      # @param rows [Array]
      # @param batch_index [Integer, nil] optional index for instrumentation
      # @return [Array(Hash), Hash] [documents, report]
      # @raise [SearchEngine::Errors::InvalidParams] on missing required fields
      def map_batch!(rows, batch_index: nil)
        start_ms = monotonic_ms
        docs = []
        stats = init_stats

        rows.each do |row|
          hash = normalize_document(@map_proc.call(row))
          update_stats_for_doc!(stats, hash)
          validate_and_coerce_types!(stats, hash)
          docs << hash
        end

        ensure_required_present!(stats)
        ensure_no_unknowns!(stats)

        duration = monotonic_ms - start_ms
        instrument_batch_mapped(
          batch_index: batch_index,
          docs_count: docs.size,
          duration_ms: duration,
          missing_required_count: stats[:missing_required].size,
          extra_keys_count: stats[:extras_samples].size,
          invalid_type_count: stats[:invalid_type_samples].size,
          coerced_count: stats[:coerced_count]
        )

        report = build_report(stats, docs.size, batch_index, duration)
        [docs, report]
      end

      private

      def default_options
        {
          strict_unknown_keys: false,
          coercions_enabled: false,
          coercion_rules: {},
          max_error_samples: 5
        }
      end

      def init_stats
        {
          missing_required: [],
          extras_samples: [],
          invalid_type_samples: [],
          coerced_count: 0,
          total_keys: 0,
          nil_id: 0
        }
      end

      def update_stats_for_doc!(stats, hash)
        stats[:total_keys] += hash.size

        id_has_key = hash.key?(:id) || hash.key?('id')
        id_value = hash[:id] || hash['id']
        stats[:nil_id] += 1 if id_has_key && id_value.nil?

        present_keys = hash.keys.map(&:to_sym)
        missing = @required_keys - present_keys
        stats[:missing_required] |= missing.to_a unless missing.empty?

        extras = present_keys.to_set - @allowed_keys
        stats[:extras_samples] |= extras.to_a unless extras.empty?
      end

      def validate_and_coerce_types!(stats, hash)
        hash.each do |key, value|
          fname = key.to_s
          expected = @types_by_field[fname]
          next unless expected

          valid, coerced, err = validate_value(expected, value, field: fname)
          if coerced
            stats[:coerced_count] += 1
            hash[key] = coerced
          elsif !valid && stats[:invalid_type_samples].size < @options[:max_error_samples]
            stats[:invalid_type_samples] << err
          end
        end
      end

      def ensure_required_present!(stats)
        return if stats[:missing_required].empty?

        message = "Missing required fields: #{stats[:missing_required].sort.inspect} for #{klass.name} mapper."
        instrument_error(error_class: 'SearchEngine::Errors::InvalidParams', message: message)
        raise SearchEngine::Errors::InvalidParams, message
      end

      def ensure_no_unknowns!(stats)
        return unless @options[:strict_unknown_keys] && !stats[:extras_samples].empty?

        message = [
          'Unknown fields detected:',
          "#{stats[:extras_samples].sort.inspect} (set mapper.strict_unknown_keys)."
        ].join(' ')
        instrument_error(error_class: 'SearchEngine::Errors::InvalidField', message: message)
        raise SearchEngine::Errors::InvalidField, message
      end

      def build_report(stats, docs_size, batch_index, duration)
        {
          collection: klass.respond_to?(:collection) ? klass.collection : nil,
          batch_index: batch_index,
          docs_count: docs_size,
          missing_required: stats[:missing_required].sort,
          extras_sample: stats[:extras_samples].sort[0, @options[:max_error_samples]],
          invalid_type_sample: stats[:invalid_type_samples][0, @options[:max_error_samples]],
          coerced_count: stats[:coerced_count],
          total_keys: stats[:total_keys],
          nil_id: stats[:nil_id],
          duration_ms: duration.round(1)
        }
      end

      def normalize_document(obj)
        return obj if obj.is_a?(Hash)
        return obj.to_h if obj.respond_to?(:to_h)
        return obj.as_json if obj.respond_to?(:as_json)

        raise SearchEngine::Errors::InvalidParams,
              'Mapper map block must return a Hash-like document (Hash/#to_h/#as_json)'
      end

      def validate_value(expected_type, value, field:)
        # Returns [valid(Boolean), coerced_value_or_nil, error_message]
        case expected_type
        when 'int64', 'int32'
          validate_integer(value, field)
        when 'float'
          validate_float(value, field)
        when 'bool'
          validate_bool(value, field)
        when 'string'
          [value.is_a?(String), nil, invalid_type_message(field, 'String', value)]
        when 'string[]'
          return [true, nil, nil] if value.is_a?(Array) && value.all? { |v| v.is_a?(String) }

          [false, nil, invalid_type_message(field, 'Array<String>', value)]
        else
          # Unknown/opaque type: accept
          [true, nil, nil]
        end
      end

      def validate_integer(value, field)
        if value.is_a?(Integer)
          [true, nil, nil]
        elsif @options[:coercions_enabled] && string_integer?(value)
          [true, Integer(value), true]
        else
          [false, nil, invalid_type_message(field, 'Integer', value)]
        end
      end

      def validate_float(value, field)
        if value.is_a?(Numeric) && finite_number?(value)
          [true, nil, nil]
        elsif @options[:coercions_enabled] && string_float?(value)
          f = begin
            Float(value)
          rescue StandardError
            nil
          end
          f && finite_number?(f) ? [true, f, true] : [false, nil, invalid_type_message(field, 'Float', value)]
        else
          [false, nil, invalid_type_message(field, 'Float', value)]
        end
      end

      def validate_bool(value, field)
        if [true, false].include?(value)
          [true, nil, nil]
        elsif @options[:coercions_enabled] && %w[true false 1 0].include?(value.to_s.downcase)
          [true, %w[true 1].include?(value.to_s.downcase), true]
        else
          [false, nil, invalid_type_message(field, 'Boolean', value)]
        end
      end

      def string_integer?(v)
        v.is_a?(String) && v.match?(/^[-+]?\d+$/)
      end

      def string_float?(v)
        v.is_a?(String) && v.match?(/^[-+]?\d*(?:\.\d+)?$/)
      end

      def finite_number?(v)
        return v.finite? if v.is_a?(Float)

        true
      end

      def invalid_type_message(field, expected, got)
        got_class = got.nil? ? 'NilClass' : got.class.name
        got_preview = got.is_a?(String) ? got[0, 50] : got.to_s[0, 50]
        "Invalid type for field :#{field} (expected #{expected}, got #{got_class}: \"#{got_preview}\")."
      end

      def instrument_batch_mapped(batch_index:, docs_count:, duration_ms:,
                                  missing_required_count:, extra_keys_count:,
                                  invalid_type_count:, coerced_count:)
        return unless defined?(ActiveSupport::Notifications)

        payload = {
          collection: klass.respond_to?(:collection) ? klass.collection : nil,
          batch_index: batch_index,
          docs_count: docs_count,
          duration_ms: duration_ms.round(1),
          missing_required_count: missing_required_count,
          extra_keys_count: extra_keys_count,
          invalid_type_count: invalid_type_count,
          coerced_count: coerced_count
        }
        ActiveSupport::Notifications.instrument('search_engine.mapper.batch_mapped', payload) {}
      end

      def instrument_error(error_class:, message:)
        return unless defined?(ActiveSupport::Notifications)

        payload = {
          collection: klass.respond_to?(:collection) ? klass.collection : nil,
          error_class: error_class,
          message: message.to_s[0, 200]
        }
        ActiveSupport::Notifications.instrument('search_engine.mapper.error', payload) {}
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      end
    end

    class << self
      # Resolve a compiled mapper for a model class, or nil if no DSL is defined.
      # @param klass [Class]
      # @return [SearchEngine::Mapper::Compiled, nil]
      def for(klass)
        dsl = mapper_dsl_for(klass)
        return nil unless dsl && dsl[:map].respond_to?(:call)

        cache[klass] ||= compile(klass, dsl)
      end

      private

      def cache
        @cache ||= {}
      end

      def compile(klass, dsl)
        compiled_schema = SearchEngine::Schema.compile(klass)
        fields = Array(compiled_schema[:fields]).map { |f| f[:name].to_s }
        types_by_field = {}
        Array(compiled_schema[:fields]).each do |f|
          types_by_field[f[:name].to_s] = f[:type].to_s
        end

        mapper_cfg = SearchEngine.config&.mapper
        coercions_cfg = mapper_cfg&.coercions || {}
        options = {
          strict_unknown_keys: mapper_cfg&.strict_unknown_keys ? true : false,
          coercions_enabled: coercions_cfg[:enabled] ? true : false,
          coercion_rules: coercions_cfg[:rules].is_a?(Hash) ? coercions_cfg[:rules] : {},
          max_error_samples: (mapper_cfg&.max_error_samples.to_i.positive? ? mapper_cfg.max_error_samples.to_i : 5)
        }

        Compiled.new(
          klass: klass,
          map_proc: dsl[:map],
          schema_fields: fields,
          types_by_field: types_by_field,
          options: options
        )
      end

      def mapper_dsl_for(klass)
        return unless klass.instance_variable_defined?(:@__mapper_dsl__)

        klass.instance_variable_get(:@__mapper_dsl__)
      end
    end
  end
end
