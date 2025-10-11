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
      end

      class_methods do
        # Delete documents by filter for this collection's physical index.
        # Accepts either a Typesense filter string (via first arg or :filter_by)
        # or a hash of field=>value which will be converted to a filter string.
        # Supports optional partition to cooperate with default_into_resolver.
        #
        # @param filter_or_str [String, nil]
        # @param filter_by [String, nil]
        # @param into [String, nil]
        # @param partition [Object, nil]
        # @param timeout_ms [Integer, nil]
        # @param hash [Hash]
        # @return [Integer] number of deleted documents
        def delete_by(filter_or_str = nil, into: nil, partition: nil, timeout_ms: nil, filter_by: nil, **hash)
          SearchEngine::Deletion.delete_by(
            klass: self,
            filter: filter_or_str || filter_by,
            hash: (hash.empty? ? nil : hash),
            into: into,
            partition: partition,
            timeout_ms: timeout_ms
          )
        end
      end

      class_methods do
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
      end

      class_methods do
        # Declare an attribute with an optional type (symbol preferred).
        #
        # @param name [#to_sym]
        # @param type [Object] type descriptor (e.g., :string, :integer)
        # @param locale [String, nil] only applicable to :string and [:string]; when set,
        #   the raw value is passed to the Typesense field's `locale`
        # @param optional [Boolean, nil] when set, the raw value is passed to the Typesense field's `optional`
        # @param sort [Boolean, nil] when set, the raw value is passed to the Typesense field's `sort`
        # @param infix [Boolean, nil] when set, the raw value is passed to the Typesense field's `infix`
        # @param empty_filtering [Boolean, nil] only applicable to array types (e.g., [:string]).
        #   When true, the gem will add an internal hidden boolean field "<name>_empty" used to
        #   support `.where(name: [])` and `.where.not(name: [])` semantics. Hidden fields are
        #   not exposed via public APIs or inspect and are populated automatically by the mapper.
        # @return [void]
        def attribute(name, type = :string, locale: nil, optional: nil, sort: nil, infix: nil, empty_filtering: nil)
          n = name.to_sym
          if n == :id
            raise SearchEngine::Errors::InvalidField,
                  'The :id field is reserved; use `identify_by` to set the Typesense document id.'
          end

          (@attributes ||= {})[n] = type

          if [locale, optional, sort, infix, empty_filtering].any? { |v| !v.nil? }
            @attribute_options ||= {}
            new_opts = __se_build_attribute_options_for(
              n, type,
              locale: locale, optional: optional, sort: sort, infix: infix, empty_filtering: empty_filtering
            )

            if new_opts.empty?
              @attribute_options = @attribute_options.dup
              @attribute_options.delete(n)
            else
              @attribute_options[n] = new_opts
            end
          elsif instance_variable_defined?(:@attribute_options) && (@attribute_options || {}).key?(n)
            # When re-declared without options, keep prior options as-is (idempotent)
          end

          # Define an instance reader for the attribute unless one already exists (idempotent)
          attr_reader n unless method_defined?(n)
          nil
        end
      end

      class_methods do
        private

        def __se_build_attribute_options_for(
          n, type, locale:,
          optional: nil, sort: nil, infix: nil, empty_filtering: nil
        )
          new_opts = (@attribute_options[n] || {}).dup

          # locale
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

          __se_apply_optional_sort_empty_filtering(
            new_opts,
            type,
            optional: optional,
            sort: sort,
            infix: infix,
            empty_filtering: empty_filtering
          )
        end

        private :__se_build_attribute_options_for
      end

      class_methods do
        # optional, sort, infix, empty_filtering extracted to a separate block to
        # satisfy Metrics/BlockLength without changing semantics.
        def __se_ensure_boolean!(name, value)
          return if [true, false].include?(value)

          raise SearchEngine::Errors::InvalidOption,
                "`#{name}` should be of boolean data type (currently is #{value.class})"
        end

        def __se_apply_optional_sort_empty_filtering(new_opts, type, optional:, sort:, infix:, empty_filtering:)
          # optional
          if optional.nil?
            new_opts.delete(:optional)
          else
            __se_ensure_boolean!(:optional, optional)
            new_opts[:optional] = optional ? true : false
          end

          # sort
          if sort.nil?
            new_opts.delete(:sort)
          else
            __se_ensure_boolean!(:sort, sort)
            new_opts[:sort] = sort ? true : false
          end

          # infix
          if infix.nil?
            new_opts.delete(:infix)
          else
            __se_ensure_boolean!(:infix, infix)
            new_opts[:infix] = infix ? true : false
          end

          # empty_filtering
          if empty_filtering.nil?
            new_opts.delete(:empty_filtering)
          else
            is_array_type = type.is_a?(Array) && type.size == 1
            unless is_array_type
              raise SearchEngine::Errors::InvalidOption,
                    "`empty_filtering` is only applicable to array types (e.g., [:string]); got #{type.inspect}"
            end
            new_opts[:empty_filtering] = empty_filtering ? true : false
          end

          new_opts
        end

        private :__se_apply_optional_sort_empty_filtering
      end

      class_methods do
        # Read-only view of declared attributes for this class.
        def attributes
          (@attributes || {}).dup.freeze
        end
      end

      class_methods do
        # Read-only view of declared per-attribute options (e.g., locale).
        def attribute_options
          (@attribute_options || {}).dup.freeze
        end
      end

      class_methods do
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
      end

      class_methods do
        # Hook to ensure subclasses inherit attributes and schema retention from their parent.
        def inherited(subclass)
          super
          parent_attrs = @attributes || {}
          subclass.instance_variable_set(:@attributes, parent_attrs.dup)

          parent_attr_opts = @attribute_options || {}
          subclass.instance_variable_set(:@attribute_options, parent_attr_opts.dup)

          parent_retention = @schema_retention || {}
          subclass.instance_variable_set(:@schema_retention, parent_retention.dup)

          parent_joins = @joins_config || {}
          subclass.instance_variable_set(:@joins_config, parent_joins.dup.freeze)

          if instance_variable_defined?(:@__declared_default_preset__)
            token = instance_variable_get(:@__declared_default_preset__)
            subclass.instance_variable_set(:@__declared_default_preset__, token)
          end

          if instance_variable_defined?(:@__model_default_query_by__)
            qb = instance_variable_get(:@__model_default_query_by__)
            subclass.instance_variable_set(:@__model_default_query_by__, qb)
          end

          return unless instance_variable_defined?(:@identify_by_proc)

          subclass.instance_variable_set(:@identify_by_proc, @identify_by_proc)
        end
      end
    end
  end
end
