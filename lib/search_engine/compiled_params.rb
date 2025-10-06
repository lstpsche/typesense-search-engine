# frozen_string_literal: true

require 'json'

module SearchEngine
  # Immutable, deterministic wrapper for compiled Typesense params.
  #
  # Guarantees:
  # - Canonicalized symbol keys and lexicographic key ordering at every hash level
  # - Array order preserved as provided
  # - Deep frozen internal representation
  # - Stable to_h and to_json across Ruby versions/runs
  #
  # Public surface mirrors a minimal read-only Hash API used in the codebase.
  # New instances should be constructed from plain Hashes only.
  class CompiledParams
    EMPTY_HASH = {}.freeze
    EMPTY_ARRAY = [].freeze

    # @param value [Hash, #to_h]
    def initialize(value)
      input = if value.is_a?(Hash)
                value
              elsif value.respond_to?(:to_h)
                value.to_h
              else
                EMPTY_HASH
              end
      @canonical = canonicalize_hash(input)
      deep_freeze!(@canonical)
      freeze
    end

    # Fast constructor from any object responding to +to_h+.
    # @param value [Object]
    # @return [SearchEngine::CompiledParams]
    def self.from(value)
      value.is_a?(self) ? value : new(value)
    end

    # Return the canonical, deeply frozen Hash (symbol keys, sorted order).
    # @return [Hash]
    def to_h
      @canonical
    end

    # Implicit Hash conversion for APIs like Hash#merge expecting #to_hash.
    # @return [Hash]
    alias to_hash to_h

    # Deterministic JSON serialization using the canonical ordered Hash.
    # @return [String]
    def to_json(*_args)
      JSON.generate(@canonical)
    end

    # Read-style Hash helpers used in callers ---------------------------------

    # @param key [Object]
    # @return [Object]
    def [](key)
      @canonical[key_to_sym(key)]
    end

    # @param key [Object]
    # @return [Boolean]
    def key?(key)
      @canonical.key?(key_to_sym(key))
    end

    # @return [Array<Symbol>]
    def keys
      @canonical.keys
    end

    # @yieldparam key [Symbol]
    # @yieldparam value [Object]
    # @return [Enumerator]
    def each(&block)
      return enum_for(:each) unless block_given?

      @canonical.each(&block)
    end

    # Equality based on canonical Hash content.
    # @param other [Object]
    # @return [Boolean]
    def ==(other)
      if other.is_a?(CompiledParams)
        other.to_h == @canonical
      elsif other.respond_to?(:to_h)
        other.to_h == @canonical
      else
        false
      end
    end

    private

    def key_to_sym(k)
      k.respond_to?(:to_sym) ? k.to_sym : k
    end

    def canonicalize_hash(hash)
      # Normalize keys to symbols; sort by key.to_s; recurse into values
      sorted_keys = hash.keys.sort_by(&:to_s)
      sorted_keys.each_with_object({}) do |k, acc|
        sym_key = key_to_sym(k)
        acc[sym_key] = canonicalize_value(hash[k])
      end
    end

    def canonicalize_array(array)
      return EMPTY_ARRAY if array.empty?

      array.map { |v| canonicalize_value(v) }
    end

    def canonicalize_value(value)
      case value
      when Hash
        canonicalize_hash(value)
      when Array
        canonicalize_array(value)
      else
        value
      end
    end

    def deep_freeze!(obj)
      case obj
      when Hash
        obj.each_value { |v| deep_freeze!(v) }
        obj.freeze
      when Array
        obj.each { |v| deep_freeze!(v) }
        obj.freeze
      else
        obj.freeze if obj.respond_to?(:freeze)
      end
    end
  end
end
