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

      # Hook to ensure subclasses inherit attributes from their parent.
      # @param subclass [Class]
      # @return [void]
      def inherited(subclass)
        super
        parent_attrs = @attributes || {}
        subclass.instance_variable_set(:@attributes, parent_attrs.dup)
      end
    end

    # TODO: In a future change, implement instance-level hydration/initialization
    # from a Typesense document using the declared {attributes} map.
  end
end
