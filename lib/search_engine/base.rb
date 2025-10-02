# frozen_string_literal: true

module SearchEngine
  # Base class for SearchEngine models.
  #
  # Provides lightweight macros to declare the backing Typesense collection and
  # a schema-like list of attributes for future hydration. Attributes declared in
  # a parent class are inherited by subclasses. Redefining an attribute in a
  # subclass overwrites only at the subclass level.
  class Base
    class << self
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

      # Declare an attribute with an optional type (symbol preferred).
      #
      # @param name [#to_sym]
      # @param type [Object] type descriptor (e.g., :string, :integer)
      # @return [void]
      def attribute(name, type = :string)
        n = name.to_sym
        (@attributes ||= {})[n] = type
        nil
      end

      # Read-only view of declared attributes for this class.
      #
      # @return [Hash{Symbol=>Object}] a frozen copy of attributes
      def attributes
        (@attributes || {}).dup.freeze
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

        parent_retention = @schema_retention || {}
        subclass.instance_variable_set(:@schema_retention, parent_retention.dup)
      end

      # Return a fresh, immutable relation bound to this model class.
      #
      # @example
      #   class Product < SearchEngine::Base; end
      #   r = Product.all
      #   r.empty? #=> true
      #
      # @return [SearchEngine::Relation]
      def all
        SearchEngine::Relation.new(self)
      end

      # Define collection-level indexing configuration and mapping.
      #
      # Usage:
      #   index do
      #     source :active_record, model: ::Product
      #     map { |r| { id: r.id, name: r.name } }
      #   end
      #
      # @yieldparam dsl [SearchEngine::Mapper::Dsl]
      # @return [void]
      def index
        raise ArgumentError, 'block required' unless block_given?

        dsl = SearchEngine::Mapper::Dsl.new(self)
        yield dsl

        definition = dsl.to_definition
        unless definition[:map].respond_to?(:call)
          raise ArgumentError, 'index requires a map { |record| ... } block returning a document'
        end

        # Store definition on the class; Mapper.for will compile and cache
        instance_variable_set(:@__mapper_dsl__, definition)
        nil
      end

      # Define a stale filter builder for delete-by-filter operations.
      #
      # The block must accept a keyword argument `partition:` and return either
      # a non-empty String (to enable deletes) or nil/blank (to disable).
      #
      # @yieldparam partition [Object, nil]
      # @yieldreturn [String, nil]
      # @return [void]
      def stale_filter_by(&block)
        raise ArgumentError, 'stale_filter_by requires a block' unless block

        instance_variable_set(:@__stale_filter_proc__, block)
        nil
      end
    end

    # TODO: In a future change, implement instance-level hydration/initialization
    # from a Typesense document using the declared {attributes} map.
  end
end
