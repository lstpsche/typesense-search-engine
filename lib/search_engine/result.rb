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

    # @return [Array<Object>] hydrated hits (frozen internal array)
    # @return [Integer] number of documents that matched the search
    # @return [Integer] number of documents searched
    # @return [Array<Hash>, nil] facet counts as returned by Typesense
    # @return [Hash] raw Typesense response (unmodified)
    attr_reader :hits, :found, :out_of, :facets, :raw

    # Build a new result wrapper.
    #
    # @param raw [Hash] Parsed Typesense response ({"hits"=>[{"document"=>{...}}], "found"=>..., "out_of"=>..., "facet_counts"=>[...]})
    # @param klass [Class, nil] Optional model class used to hydrate each document
    def initialize(raw, klass: nil)
      require 'ostruct'

      @raw   = raw || {}
      @found = @raw['found']
      @out_of = @raw['out_of']
      @facets = @raw['facet_counts']
      @klass  = klass

      documents = Array(@raw['hits']).map { |h| h && h['document'] }.compact
      hydrated = documents.map { |doc| hydrate(doc) }

      @hits = hydrated.freeze
      freeze # make the wrapper itself immutable
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

    private

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

    def ivar_name(key)
      @ivar_prefix_cache ||= {}
      @ivar_prefix_cache[key] ||= "@#{key}"
    end
  end
end
