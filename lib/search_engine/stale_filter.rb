# frozen_string_literal: true

module SearchEngine
  # Compiles and validates a collection-level stale filter callable.
  #
  # Provides an immutable object that can safely produce a Typesense `filter_by`
  # expression for a given partition. The supplied block must accept a
  # `partition:` keyword argument and return either a non-empty String (to
  # enable deletion) or nil/blank (to disable).
  module StaleFilter
    # Immutable compiled holder for stale filter callable.
    class Compiled
      # @return [Class]
      attr_reader :klass

      # @param klass [Class]
      # @param filter_proc [Proc]
      def initialize(klass:, filter_proc:)
        @klass = klass
        validate_signature!(filter_proc)
        @filter_proc = filter_proc
        @partition_kw = detect_partition_keyword(filter_proc)
        freeze
      end

      # Build a filter string for the given partition.
      #
      # @param partition [Object, nil]
      # @return [String, nil] non-empty filter string or nil when disabled
      # @raise [SearchEngine::Errors::InvalidParams] when the block returns a non-String
      def call(partition: nil)
        str = @filter_proc.call(@partition_kw => partition)
        return nil if str.nil?

        unless str.is_a?(String)
          raise SearchEngine::Errors::InvalidParams,
                'stale_filter_by block must return a String or nil'
        end

        s = str.to_s
        s.strip.empty? ? nil : s
      end

      private

      def validate_signature!(proc_obj)
        params = proc_obj.parameters
        # Accept either optional or required keyword for :partition. Allow underscore-prefixed name (:_partition).
        has_partition_kw = params.any? do |(kind, name)|
          %i[key keyreq].include?(kind) && %i[partition _partition].include?(name)
        end
        return if has_partition_kw

        raise SearchEngine::Errors::InvalidParams,
              'stale_filter_by block must accept a keyword argument `partition:`'
      end

      def detect_partition_keyword(proc_obj)
        params = proc_obj.parameters
        params.each do |(kind, name)|
          next unless %i[key keyreq].include?(kind)

          return :partition if name == :partition
          return :_partition if name == :_partition
        end
        :partition
      end
    end

    class << self
      # Resolve a compiled stale filter for a model class, or nil if undefined.
      # @param klass [Class]
      # @return [SearchEngine::StaleFilter::Compiled, nil]
      def for(klass)
        proc_obj = stale_filter_proc_for(klass)
        return nil unless proc_obj

        cache[klass] ||= Compiled.new(klass: klass, filter_proc: proc_obj)
      end

      private

      def cache
        @cache ||= {}
      end

      def stale_filter_proc_for(klass)
        return unless klass.instance_variable_defined?(:@__stale_filter_proc__)

        klass.instance_variable_get(:@__stale_filter_proc__)
      end
    end
  end
end
