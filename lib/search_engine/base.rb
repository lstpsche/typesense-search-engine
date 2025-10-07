# frozen_string_literal: true

require 'forwardable'

module SearchEngine
  # Base class for SearchEngine models.
  #
  # Provides lightweight macros to declare the backing Typesense collection and
  # a schema-like list of attributes for future hydration. Attributes declared in
  # a parent class are inherited by subclasses. Redefining an attribute in a
  # subclass overwrites only at the subclass level.
  class Base
    class << self
      # Enable AR-like class-level chaining by delegating DSL and materializers
      # to a fresh Relation via `.all`. This allows calls like:
      #   Product.where(id: 1).order(:updated_at).per(5)
      #   Product.count
      #   Product.pluck(:id)
      # without requiring an explicit `.all` in user code.
      #
      # Uses stdlib SingleForwardable to avoid hard dependency on ActiveSupport.
      extend SingleForwardable

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

        # Inherit joins registry via copy-on-write snapshot
        parent_joins = @joins_config || {}
        subclass.instance_variable_set(:@joins_config, parent_joins.dup.freeze)

        # Inherit declared default preset token if present
        return unless instance_variable_defined?(:@__declared_default_preset__)

        token = instance_variable_get(:@__declared_default_preset__)
        subclass.instance_variable_set(:@__declared_default_preset__, token)
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

      # Delegate Relation DSL chainers to `.all` for AR-style usage.
      # @!method where(*args)
      #   @see SearchEngine::Relation::DSL::Filters#where
      # @!method rewhere(input, *args)
      #   @see SearchEngine::Relation::DSL::Filters#rewhere
      # @!method order(value)
      #   @see SearchEngine::Relation::DSL#order
      # @!method preset(name, mode: :merge)
      #   @see SearchEngine::Relation::DSL#preset
      # @!method ranking(**opts)
      #   @see SearchEngine::Relation::DSL#ranking
      # @!method prefix(mode)
      #   @see SearchEngine::Relation::DSL#prefix
      # @!method pin(*ids)
      #   @see SearchEngine::Relation::DSL#pin
      # @!method hide(*ids)
      #   @see SearchEngine::Relation::DSL#hide
      # @!method curate(pin: nil, hide: nil, override_tags: nil, filter_curated_hits: :__unset__)
      #   @see SearchEngine::Relation::DSL#curate
      # @!method clear_curation
      #   @see SearchEngine::Relation::DSL#clear_curation
      # @!method facet_by(field, max_values: nil, sort: nil, stats: nil)
      #   @see SearchEngine::Relation::DSL#facet_by
      # @!method facet_query(field, expression, label: nil)
      #   @see SearchEngine::Relation::DSL#facet_query
      # @!method group_by(field, limit: nil, missing_values: false)
      #   @see SearchEngine::Relation::DSL#group_by
      # @!method unscope(*parts)
      #   @see SearchEngine::Relation::DSL#unscope
      # @!method limit(n)
      #   @see SearchEngine::Relation::DSL#limit
      # @!method offset(n)
      #   @see SearchEngine::Relation::DSL#offset
      # @!method page(n)
      #   @see SearchEngine::Relation::DSL#page
      # @!method per_page(n)
      #   @see SearchEngine::Relation::DSL#per_page
      # @!method per(n)
      #   @see SearchEngine::Relation::DSL#per
      # @!method options(opts = {})
      #   @see SearchEngine::Relation::DSL#options
      # @!method joins(*assocs)
      #   @see SearchEngine::Relation::DSL#joins
      # @!method use_synonyms(value)
      #   @see SearchEngine::Relation::DSL#use_synonyms
      # @!method use_stopwords(value)
      #   @see SearchEngine::Relation::DSL#use_stopwords
      # @!method select(*fields)
      #   @see SearchEngine::Relation::DSL::Selection#select
      # @!method include_fields(*fields)
      #   @see SearchEngine::Relation::DSL::Selection#include_fields
      # @!method exclude(*fields)
      #   @see SearchEngine::Relation::DSL::Selection#exclude
      # @!method reselect(*fields)
      #   @see SearchEngine::Relation::DSL::Selection#reselect
      # @!method limit_hits(n)
      #   @see SearchEngine::Relation::DSL#limit_hits
      # @!method validate_hits!(max:)
      #   @see SearchEngine::Relation::DSL#validate_hits!
      def_single_delegators :all,
                            :where, :rewhere, :order, :preset, :ranking, :prefix,
                            :pin, :hide, :curate, :clear_curation,
                            :facet_by, :facet_query, :group_by, :unscope,
                            :limit, :offset, :page, :per_page, :per, :options,
                            :joins, :use_synonyms, :use_stopwords,
                            :select, :include_fields, :exclude, :reselect,
                            :limit_hits, :validate_hits!

      # Delegate materializers to `.all` so callers can do `Model.first` etc.
      # @!method to_a
      #   @return [Array<Object>]
      # @!method each(&block)
      #   @return [Enumerator]
      # @!method first(n = nil)
      #   @return [Object, Array<Object>]
      # @!method last(n = nil)
      #   @return [Object, Array<Object>]
      # @!method take(n = 1)
      #   @return [Object, Array<Object>]
      # @!method ids
      #   @return [Array<Object>]
      # @!method pluck(*fields)
      #   @return [Array<Object>, Array<Array<Object>>]
      # @!method exists?
      #   @return [Boolean]
      # @!method count
      #   @return [Integer]
      # @!method execute
      #   @return [SearchEngine::Result]
      def_single_delegators :all,
                            :to_a, :each, :first, :last, :take, :ids, :pluck,
                            :exists?, :count, :execute

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
      def index(&block)
        raise ArgumentError, 'index requires a block' unless block

        dsl = SearchEngine::Mapper::Dsl.new(self)
        # Support both styles:
        # - index { source :active_record, ...; map { ... } }
        # - index { |dsl| dsl.source :active_record, ...; dsl.map { ... } }
        if block.arity == 1
          yield dsl
        else
          dsl.instance_eval(&block)
        end

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

      # Declare a joinable association for server-side joins.
      #
      # Registers a normalized, immutable configuration record under the provided
      # name. Duplicate names raise with an actionable message. Validation ensures
      # collection is present and local_key is a declared attribute (when available).
      #
      # @param name [#to_sym] logical association name
      # @param collection [#to_s] target collection name
      # @param local_key [#to_sym] local attribute used for join key
      # @param foreign_key [#to_sym] foreign key name in the target collection
      # @return [void]
      # @raise [ArgumentError] when inputs are invalid or duplicate name
      # @see docs/joins.md for usage and compile-time instrumentation
      def join(name, collection:, local_key:, foreign_key:)
        assoc_name = name.to_sym
        raise ArgumentError, 'join name must be non-empty' if assoc_name.to_s.strip.empty?

        coll = collection.to_s
        raise ArgumentError, 'collection must be a non-empty String' if coll.strip.empty?

        lk = local_key.to_sym
        fk = foreign_key.to_sym

        # Validate local_key against declared attributes when available
        if instance_variable_defined?(:@attributes) && !(@attributes || {}).key?(lk)
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

      # Read-only view of join declarations for this class.
      #
      # Returns a frozen Hash mapping association name => configuration record.
      # Inheritance uses a snapshot copy-on-write strategy: subclasses start with
      # the parent's snapshot and subsequent writes do not mutate the parent.
      #
      # @return [Hash{Symbol=>Hash}]
      def joins_config
        (@joins_config || {}).dup.freeze
      end

      # Lookup a single join configuration by name.
      #
      # @param name [#to_sym]
      # @return [Hash] normalized configuration record
      # @raise [SearchEngine::Errors::UnknownJoin]
      def join_for(name)
        key = name.to_sym
        cfg = (@joins_config || {})[key]
        return cfg if cfg

        available = (@joins_config || {}).keys
        raise SearchEngine::Errors::UnknownJoin,
              "Unknown join :#{key} for #{self}. Available: #{available.inspect}."
      end

      # Declare a default preset token for this collection.
      #
      # Stores the declared token as a Symbol without namespace. Validation
      # ensures presence and shape. The effective preset name is computed by
      # {default_preset_name} using the global presets configuration.
      #
      # @param name [#to_sym] declared preset token (without namespace)
      # @return [void]
      # @raise [ArgumentError] when the token is nil, blank, or invalid
      # @see docs/presets.md#config-default-preset
      def default_preset(name)
        raise ArgumentError, 'default_preset requires a name' if name.nil?

        token = name.to_sym
        raise ArgumentError, 'default_preset name must be non-empty' if token.to_s.strip.empty?

        instance_variable_set(:@__declared_default_preset__, token)
        nil
      end

      # Compute the effective default preset name for this collection.
      #
      # Applies the global presets configuration: when enabled and a namespace
      # is present, returns "#{SearchEngine.config.presets.namespace}_#{token}";
      # otherwise returns the declared token as a String. When disabled, the
      # namespace is ignored and the token is returned as a String.
      #
      # @return [String, nil] effective preset name, or nil when no preset declared
      # @see docs/presets.md#config-default-preset
      def default_preset_name
        token = if instance_variable_defined?(:@__declared_default_preset__)
                  instance_variable_get(:@__declared_default_preset__)
                end
        return nil if token.nil?

        presets_cfg = SearchEngine.config.presets
        if presets_cfg.enabled && presets_cfg.namespace
          +"#{presets_cfg.namespace}_#{token}"
        else
          token.to_s
        end
      end

      # Build a new instance from a Typesense document assigning only declared
      # attributes and capturing any extra keys in {#unknown_attributes}.
      #
      # Unknown keys are preserved as a String-keyed Hash to avoid symbol bloat.
      #
      # @param doc [Hash] a document as returned by Typesense
      # @return [Object] hydrated instance
      def from_document(doc)
        obj = new
        declared = attributes # { Symbol => type }
        unknown = {}

        (doc || {}).each do |k, v|
          key_str = k.to_s
          key_sym = key_str.to_sym
          if declared.key?(key_sym)
            obj.instance_variable_set("@#{key_sym}", v)
          else
            unknown[key_str] = v
          end
        end

        obj.instance_variable_set(:@__unknown_attributes__, unknown.freeze) unless unknown.empty?
        obj
      end
    end

    # Return a shallow copy of unknown attributes captured during hydration.
    # Keys are Strings and values are as returned by the backend.
    # @return [Hash{String=>Object}]
    def unknown_attributes
      h = instance_variable_get(:@__unknown_attributes__)
      h ? h.dup : {}
    end
  end
end
