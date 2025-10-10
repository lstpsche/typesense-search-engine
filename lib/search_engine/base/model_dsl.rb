# frozen_string_literal: true

require 'active_support/concern'

module SearchEngine
  class Base
    # Model-level DSL for declaring collections, attributes, and inheritance.
    module ModelDsl
      extend ActiveSupport::Concern

      class_methods do
        # Get or set the Typesense collection name for this model.
        #
        # When setting, the name is normalized to String and the mapping is
        # registered in the global collection registry.
        #
        # @param name [#to_s, nil]
        # @return [String, Class] returns the current collection name when reading;
        #   returns self when setting (for macro chaining)
        def collection(name = nil)
          return @collection if name.nil?

          normalized = name.to_s
          raise ArgumentError, 'collection name must be non-empty' if normalized.strip.empty?

          @collection = normalized
          SearchEngine.register_collection!(@collection, self)
          self
        end

        # Set or get the per-collection default query_by fields.
        #
        # Accepts a String (comma-separated), a Symbol, or an Array of Strings/Symbols.
        # Values are normalized into a canonical comma-separated String with single
        # spaces after commas (e.g., "name, brand, description"). When called
        # without arguments, returns the canonical String or nil if unset.
        #
        # @param values [Array<String,Symbol,Array>] zero or more field tokens; Arrays are flattened
        # @return [String, Class] returns the canonical String on read; returns self on write
        def query_by(*values)
          return @__model_default_query_by__ if values.nil? || values.empty?

          flat = values.flatten(1).compact

          list = if flat.size == 1 && flat.first.is_a?(String)
                   flat.first.split(',').map { |s| s.to_s.strip }.reject(&:empty?)
                 else
                   flat.map do |v|
                     case v
                     when String, Symbol then v.to_s.strip
                     else
                       raise ArgumentError, 'query_by accepts Symbols, Strings, or Arrays thereof'
                     end
                   end.reject(&:empty?)
                 end

          canonical = list.join(', ')
          @__model_default_query_by__ = canonical.empty? ? nil : canonical
          self
        end

        # Declare an attribute with an optional type (symbol preferred).
        #
        # @param name [#to_sym]
        # @param type [Object] type descriptor (e.g., :string, :integer)
        # @param locale [String, nil] only applicable to :string and [:string]; when set,
        #   the raw value is passed to the Typesense field's `locale`
        # @param optional [Boolean, nil] when set, the raw value is passed to the Typesense field's `optional`
        # @param sort [Boolean, nil] when set, the raw value is passed to the Typesense field's `sort`
        # @param empty_filtering [Boolean, nil] only applicable to array types (e.g., [:string]).
        #   When true, the gem will add an internal hidden boolean field "<name>_empty" used to
        #   support `.where(name: [])` and `.where.not(name: [])` semantics. Hidden fields are
        #   not exposed via public APIs or inspect and are populated automatically by the mapper.
        # @return [void]
        def attribute(name, type = :string, locale: nil, optional: nil, sort: nil, empty_filtering: nil)
          n = name.to_sym
          if n == :id
            raise SearchEngine::Errors::InvalidField,
                  'The :id field is reserved; use `identify_by` to set the Typesense document id.'
          end
          (@attributes ||= {})[n] = type
          # Validate and persist per-attribute options: locale, optional, sort, empty_filtering
          if [locale, optional, sort, empty_filtering].any? { |v| !v.nil? }
            @attribute_options ||= {}
            new_opts = (@attribute_options[n] || {}).dup

            if locale.nil?
              new_opts.delete(:locale)
            else
              is_string = type.to_s.downcase == 'string'
              is_string_array = type.is_a?(Array) && type.size == 1 && type.first.to_s.downcase == 'string'
              unless is_string || is_string_array
                raise SearchEngine::Errors::InvalidOption,
                      "`locale` is only applicable to :string and [:string] (got #{type.inspect})"
              end
              new_opts[:locale] = locale.to_s
            end

            if optional.nil?
              new_opts.delete(:optional)
            else
              unless [true, false].include?(optional)
                raise SearchEgine::Errors::InvalidOption,
                      "`optional` should be of boolean data type (currently is #{optional.class})"
              end
              new_opts[:optional] = optional
            end

            if sort.nil?
              new_opts.delete(:sort)
            else
              unless [true, false].include?(sort)
                raise SearchEgine::Errors::InvalidOption,
                      "`sort` should be of boolean data type (currently is #{sort.class})"
              end
              new_opts[:sort] = sort
            end

            if empty_filtering.nil?
              new_opts.delete(:empty_filtering)
            else
              is_array_type = type.is_a?(Array) && type.size == 1
              unless is_array_type
                raise SearchEngine::Errors::InvalidOption,
                      "`empty_filtering` is only applicable to array types (e.g., [:string]); got #{type.inspect}"
              end
              new_opts[:empty_filtering] = !!empty_filtering # rubocop:disable Style/DoubleNegation
            end

            if new_opts.empty?
              # Remove stored options for this field if none remain
              @attribute_options = @attribute_options.dup
              @attribute_options.delete(n)
            else
              @attribute_options[n] = new_opts
            end
          elsif instance_variable_defined?(:@attribute_options) && (@attribute_options || {}).key?(n)
            # When re-declared without options, keep prior options as-is (idempotent)
          end
          # Define an instance reader for the attribute unless one already exists.
          # Idempotent across repeated declarations and inheritance.
          attr_reader n unless method_defined?(n)
          nil
        end

        # Read-only view of declared attributes for this class.
        #
        # @return [Hash{Symbol=>Object}] a frozen copy of attributes
        def attributes
          (@attributes || {}).dup.freeze
        end

        # Read-only view of declared per-attribute options (e.g., locale).
        #
        # @return [Hash{Symbol=>Hash}] frozen copy of options map
        def attribute_options
          (@attribute_options || {}).dup.freeze
        end

        # Configure schema retention policy for this collection.
        # @param keep_last [Integer] how many previous physicals to keep after swap
        # @return [void]
        def schema_retention(keep_last: nil)
          return (@schema_retention || {}).dup.freeze if keep_last.nil?

          value = Integer(keep_last)
          raise ArgumentError, 'keep_last must be >= 0' if value.negative?

          @schema_retention ||= {}
          @schema_retention[:keep_last] = value
          nil
        end

        # Hook to ensure subclasses inherit attributes and schema retention from their parent.
        # @param subclass [Class]
        # @return [void]
        def inherited(subclass)
          super
          parent_attrs = @attributes || {}
          subclass.instance_variable_set(:@attributes, parent_attrs.dup)

          # Inherit per-attribute options via copy-on-write snapshot
          parent_attr_opts = @attribute_options || {}
          subclass.instance_variable_set(:@attribute_options, parent_attr_opts.dup)

          parent_retention = @schema_retention || {}
          subclass.instance_variable_set(:@schema_retention, parent_retention.dup)

          # Inherit joins registry via copy-on-write snapshot
          parent_joins = @joins_config || {}
          subclass.instance_variable_set(:@joins_config, parent_joins.dup.freeze)

          # Inherit declared default preset token if present
          if instance_variable_defined?(:@__declared_default_preset__)
            token = instance_variable_get(:@__declared_default_preset__)
            subclass.instance_variable_set(:@__declared_default_preset__, token)
          end

          # Inherit model-level default query_by if present
          if instance_variable_defined?(:@__model_default_query_by__)
            qb = instance_variable_get(:@__model_default_query_by__)
            subclass.instance_variable_set(:@__model_default_query_by__, qb)
          end

          return unless instance_variable_defined?(:@identify_by_proc)

          # Propagate identity strategy to subclasses
          subclass.instance_variable_set(:@identify_by_proc, @identify_by_proc)
        end
      end
    end
  end
end
