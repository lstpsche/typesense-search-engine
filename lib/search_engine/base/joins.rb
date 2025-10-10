# frozen_string_literal: true

require 'active_support/concern'

module SearchEngine
  class Base
    # Join declarations for server-side joins.
    module Joins
      extend ActiveSupport::Concern

      class_methods do
        # Declare a joinable association for server-side joins.
        # @param name [#to_sym]
        # @param collection [#to_s]
        # @param local_key [#to_sym]
        # @param foreign_key [#to_sym]
        # @return [void]
        def join(name, collection:, local_key:, foreign_key:)
          assoc_name = name.to_sym
          raise ArgumentError, 'join name must be non-empty' if assoc_name.to_s.strip.empty?

          coll = collection.to_s
          raise ArgumentError, 'collection must be a non-empty String' if coll.strip.empty?

          lk = local_key.to_sym
          fk = foreign_key.to_sym

          # Validate local_key against declared attributes when available (allow :id implicitly)
          if instance_variable_defined?(:@attributes) && lk != :id && !(@attributes || {}).key?(lk)
            raise SearchEngine::Errors::InvalidField,
                  "Unknown local_key :#{lk} for #{self}. Declare 'attribute :#{lk}, :integer' first."
          end

          rec = {
            name: assoc_name,
            collection: coll,
            local_key: lk,
            foreign_key: fk
          }.freeze

          current = @joins_config || {}
          if current.key?(assoc_name)
            raise ArgumentError,
                  "Join :#{assoc_name} already defined for #{self}. " \
                  'Use a different name or remove the previous declaration.'
          end

          # copy-on-write write path
          new_map = current.dup
          new_map[assoc_name] = rec
          @joins_config = new_map.freeze

          # lightweight instrumentation (no-op if AS::N is unavailable)
          SearchEngine::Instrumentation.instrument(
            'search_engine.joins.declared',
            model: self.name, name: assoc_name, collection: coll
          )

          nil
        end
      end

      class_methods do
        # Read-only view of join declarations for this class.
        # @return [Hash{Symbol=>Hash}]
        def joins_config
          (@joins_config || {}).dup.freeze
        end
      end

      class_methods do
        # Lookup a single join configuration by name.
        # @param name [#to_sym]
        # @return [Hash]
        # @raise [SearchEngine::Errors::UnknownJoin]
        def join_for(name)
          key = name.to_sym
          cfg = (@joins_config || {})[key]
          return cfg if cfg

          available = (@joins_config || {}).keys
          raise SearchEngine::Errors::UnknownJoin,
                "Unknown join :#{key} for #{self}. Available: #{available.inspect}."
        end
      end
    end
  end
end
