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
      %i[
        where rewhere order preset ranking prefix
        pin hide curate clear_curation
        facet_by facet_query group_by unscope
        limit offset page per_page per options
        joins use_synonyms use_stopwords
        select include_fields exclude reselect
        limit_hits validate_hits!
        first last take pluck exists? count
        raw
      ].each { |method| delegate method, to: :all }

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

      # Configure how to compute the Typesense document id for this collection.
      #
      # Accepts either a Symbol/String referring to a record method name, or a Proc/Lambda
      # that takes the source record and returns the id value. The value is coerced to String.
      #
      # When not configured, the default is +record.id.to_s+.
      #
      # @param strategy [Symbol, String, Proc] method name or callable
      # @yield [record] optional block form to compute id
      # @yieldparam record [Object]
      # @return [Class] self (for macro chaining)
      # @raise [SearchEngine::Errors::InvalidOption] when inputs are invalid
      def identify_by(strategy = nil, &block)
        callable = if block_given?
                     block
                   elsif strategy.is_a?(Proc)
                     if strategy.arity != 1 && strategy.arity != -1
                       raise SearchEngine::Errors::InvalidOption,
                             'identify_by Proc/Lambda must accept exactly 1 argument (record)'
                     end

                     strategy
                   elsif strategy.is_a?(Symbol) || strategy.is_a?(String)
                     meth = strategy.to_s
                     ->(record) { record.public_send(meth) }
                   else
                     raise SearchEngine::Errors::InvalidOption,
                           'identify_by expects a Symbol/String method name or a Proc/Lambda (or block)'
                   end

        # Normalize to a proc that always returns String
        @identify_by_proc = lambda do |record|
          val = callable.call(record)
          val.is_a?(String) ? val : val.to_s
        end
        self
      end

      # Compute the Typesense document id for a given source record using the configured
      # identity strategy (or the default +record.id.to_s+ when unset).
      # @param record [Object]
      # @return [String]
      def compute_document_id(record)
        val =
          if instance_variable_defined?(:@identify_by_proc) && (proc = @identify_by_proc)
            proc.call(record)
          else
            record.respond_to?(:id) ? record.id : nil
          end
        val.is_a?(String) ? val : val.to_s
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

      # Run indexing workflow for this collection.
      #
      # Full flow (partition: nil):
      # 1. Presence check
      # 2. If missing -> create collection and apply schema (with reindex)
      # 3. If present -> check schema drift
      # 4. If drift -> apply schema (with reindex)
      # 5. If nothing applied -> index current collection (single or partitioned)
      # 6. Retention cleanup (skipped when Schema.apply! already ran)
      #
      # Partial flow (partition provided):
      # 1. Presence check; quit if missing
      # 2. Schema drift check; quit if drift
      # 3. Reindex only the provided partition(s)
      #
      # @param partition [Object, Array<Object>, nil]
      # @param client [SearchEngine::Client, nil]
      # @return [void]
      # @example Full indexation flow
      #   SearchEngine::Product.indexate
      # @example Partitioned indexation
      #   SearchEngine::Product.indexate(partition: shop_id)
      #   SearchEngine::Product.indexate(partition: [shop_id_1, shop_id_2])
      def indexate(partition: nil, client: nil)
        client_obj = client || (SearchEngine.config.respond_to?(:client) && SearchEngine.config.client) || SearchEngine::Client.new

        if partition.nil?
          __se_indexate_full(client: client_obj)
        else
          __se_indexate_partial(partition: partition, client: client_obj)
        end
        nil
      end

      # Rebuild one or many partitions inline using the Indexer.
      #
      # Accepts an opaque partition key or an Array of keys, as defined by the
      # collection's partitioning DSL. When an Array is provided, each partition
      # is rebuilt sequentially and the method returns a list of summaries.
      #
      # @param partition [Object, Array<Object>, nil]
      # @param into [String, nil] optional physical collection override
      # @return [SearchEngine::Indexer::Summary, Array<SearchEngine::Indexer::Summary>]
      # @example Single partition
      #   SearchEngine::Product.rebuild_partition!(partition: 1031)
      # @example Multiple partitions
      #   SearchEngine::Product.rebuild_partition!(partition: [1030, 1031])
      def rebuild_partition!(partition:, into: nil)
        parts = if partition.nil? || (partition.respond_to?(:empty?) && partition.empty?)
                  [nil]
                else
                  Array(partition)
                end

        return SearchEngine::Indexer.rebuild_partition!(self, partition: parts.first, into: into) if parts.size == 1

        parts.map { |p| SearchEngine::Indexer.rebuild_partition!(self, partition: p, into: into) }
      end

      # Return the compiled Typesense schema for this collection model.
      #
      # Uses the model's declared attributes and options to build a deterministic
      # Typesense-compatible schema hash. The result is deeply frozen.
      #
      # @return [Hash] compiled schema with symbol keys
      def schema
        SearchEngine::Schema.compile(self)
      end

      # Retrieve the current live schema of the Typesense collection.
      #
      # Resolves the logical collection name to the current physical collection
      # via alias when present, then fetches the collection schema from Typesense.
      # Returns nil when the collection is missing.
      #
      # @return [Hash, nil] live collection schema (symbolized) or nil when missing
      def current_schema
        client = (SearchEngine.config.respond_to?(:client) && SearchEngine.config.client) || SearchEngine::Client.new
        logical = respond_to?(:collection) ? collection.to_s : name.to_s
        physical = client.resolve_alias(logical) || logical
        client.retrieve_collection_schema(physical)
      end

      # Compute the diff between the model's compiled schema and the live schema in Typesense.
      #
      # The return value matches the structured diff hash produced by
      # {SearchEngine::Schema.diff}, excluding the pretty-printed summary.
      #
      # @return [Hash] diff hash with keys: :collection, :added_fields, :removed_fields, :changed_fields, :collection_options
      def schema_diff
        client = (SearchEngine.config.respond_to?(:client) && SearchEngine.config.client) || SearchEngine::Client.new
        res = SearchEngine::Schema.diff(self, client: client)
        res[:diff]
      end

      # Drop this model's Typesense collection.
      #
      # Resolves the alias for the logical collection name and drops the current
      # physical target when present. If no alias exists, attempts to drop a
      # collection with the logical name directly. Verbose progress is printed
      # to STDOUT. No-op when the collection does not exist.
      #
      # @return [void]
      def drop_collection!
        client = (SearchEngine.config.respond_to?(:client) && SearchEngine.config.client) || SearchEngine::Client.new
        logical = respond_to?(:collection) ? collection.to_s : name.to_s

        alias_target = client.resolve_alias(logical)
        physical = if alias_target && !alias_target.to_s.strip.empty?
                     alias_target.to_s
                   else
                     live = client.retrieve_collection_schema(logical)
                     live ? logical : nil
                   end

        if physical.nil?
          puts('Drop Collection — skip (not present)')
          return
        end

        puts("Drop Collection — processing (logical=#{logical} physical=#{physical})")
        client.delete_collection(physical)
        puts('Drop Collection — done')
        nil
      end

      # Recreate this model's Typesense collection (drop if present, then create).
      #
      # Resolves the alias for the logical collection name and drops the current
      # physical target when present. Then creates a new collection using the
      # compiled schema for this model with the logical collection name. Verbose
      # progress is printed to STDOUT.
      #
      # Note: This method does not modify aliases; if an alias was pointing to
      # a previously dropped physical collection, it will remain pointing to a
      # non-existent target until updated elsewhere.
      #
      # @return [void]
      def recreate_collection!
        client = (SearchEngine.config.respond_to?(:client) && SearchEngine.config.client) || SearchEngine::Client.new
        logical = respond_to?(:collection) ? collection.to_s : name.to_s

        alias_target = client.resolve_alias(logical)
        physical = if alias_target && !alias_target.to_s.strip.empty?
                     alias_target.to_s
                   else
                     live = client.retrieve_collection_schema(logical)
                     live ? logical : nil
                   end

        if physical
          puts("Recreate Collection — dropping existing (logical=#{logical} physical=#{physical})")
          client.delete_collection(physical)
        else
          puts('Recreate Collection — no existing collection (skip drop)')
        end

        schema = SearchEngine::Schema.compile(self)
        puts("Recreate Collection — creating collection with schema (logical=#{logical})")
        client.create_collection(schema)
        puts('Recreate Collection — done')
        nil
      end

      private

      # --------------------------- Full flow ---------------------------
      def __se_indexate_full(client:)
        logical = respond_to?(:collection) ? collection.to_s : name.to_s

        # Step 1: Presence
        diff_res = SearchEngine::Schema.diff(self, client: client)
        diff = diff_res[:diff] || {}
        missing = __se_schema_missing?(diff)
        puts("Step 1: Presence — processing → #{missing ? 'missing' : 'present'}")

        applied = false
        indexed_inside_apply = false

        # Step 2: Create + apply schema if missing
        if missing
          puts('Step 2: Create+Apply Schema — processing')
          SearchEngine::Schema.apply!(self, client: client) do |new_physical|
            __se_index_partitions!(into: new_physical)
            indexed_inside_apply = true
          end
          applied = true
          puts('Step 2: Create+Apply Schema — done')
        else
          puts('Step 2: Create+Apply Schema — skip (already present)')
        end

        # Step 3: Check schema status (only when present initially)
        drift = false
        if !missing
          puts('Step 3: Check Schema Status — processing')
          drift = __se_schema_drift?(diff)
          puts("Step 3: Check Schema Status — #{drift ? 'drift' : 'in_sync'}")
        else
          puts('Step 3: Check Schema Status — skip (just created)')
        end

        # Step 4: Apply new schema when drift detected
        if drift
          puts('Step 4: Apply New Schema — processing')
          SearchEngine::Schema.apply!(self, client: client) do |new_physical|
            __se_index_partitions!(into: new_physical)
            indexed_inside_apply = true
          end
          applied = true
          puts('Step 4: Apply New Schema — done')
        else
          puts('Step 4: Apply New Schema — skip')
        end

        # Step 5: Indexation (when nothing was applied)
        if applied && indexed_inside_apply
          puts('Step 5: Indexation — skip (performed during schema apply)')
        else
          puts('Step 5: Indexation — processing')
          __se_index_partitions!(into: nil)
          puts('Step 5: Indexation — done')
        end

        # Step 6: Retention cleanup
        if applied
          puts('Step 6: Retention Cleanup — skip (handled by schema apply)')
        else
          puts('Step 6: Retention Cleanup — processing')
          dropped = __se_retention_cleanup!(logical: logical, client: client)
          puts("Step 6: Retention Cleanup — dropped=#{dropped.inspect}")
        end
      end

      # -------------------------- Partial flow -------------------------
      def __se_indexate_partial(partition:, client:)
        partitions = Array(partition)
        diff_res = SearchEngine::Schema.diff(self, client: client)
        diff = diff_res[:diff] || {}

        # Step 1: Presence
        missing = __se_schema_missing?(diff)
        puts("Step 1: Presence — processing → #{missing ? 'missing' : 'present'}")
        if missing
          puts('Partial: collection is not present. Quit early.')
          return
        end

        # Step 2: Schema status
        puts('Step 2: Check Schema Status — processing')
        drift = __se_schema_drift?(diff)
        if drift
          puts('Partial: schema is not up-to-date. Quit early (run full indexation).')
          return
        end
        puts('Step 2: Check Schema Status — in_sync')

        # Step 3: Partial indexing
        puts('Step 3: Partial Indexation — processing')
        partitions.each do |p|
          summary = SearchEngine::Indexer.rebuild_partition!(self, partition: p, into: nil)
          sample_err = __se_extract_sample_error(summary)
          puts(
            "  partition=#{p.inspect} → status=#{summary.status} docs=#{summary.docs_total} " \
            "failed=#{summary.failed_total} batches=#{summary.batches_total} duration_ms=#{summary.duration_ms_total}" \
            "#{sample_err ? " sample_error=#{sample_err.inspect}" : ''}"
          )
        end
        puts('Step 3: Partial Indexation — done')
      end

      # ----------------------------- Helpers ---------------------------
      def __se_schema_missing?(diff)
        opts = diff[:collection_options]
        opts.is_a?(Hash) && opts[:live] == :missing
      end

      def __se_schema_drift?(diff)
        added = Array(diff[:added_fields])
        removed = Array(diff[:removed_fields])
        changed = (diff[:changed_fields] || {}).to_h
        coll_opts = (diff[:collection_options] || {}).to_h
        added.any? || removed.any? || !changed.empty? || !coll_opts.empty?
      end

      def __se_extract_sample_error(summary)
        failed = begin
          summary.respond_to?(:failed_total) ? summary.failed_total.to_i : 0
        rescue StandardError
          0
        end
        return nil if failed <= 0

        batches = begin
          summary.respond_to?(:batches) ? summary.batches : nil
        rescue StandardError
          nil
        end
        return nil unless batches.is_a?(Array)

        batches.each do |b|
          next unless b.is_a?(Hash)

          samples = b[:errors_sample] || b['errors_sample']
          next if samples.nil?

          Array(samples).each do |m|
            s = m.to_s
            return s unless s.strip.empty?
          end
        end
        nil
      end

      def __se_index_partitions!(into:)
        compiled = SearchEngine::Partitioner.for(self)
        if compiled
          compiled.partitions.each do |part|
            summary = SearchEngine::Indexer.rebuild_partition!(self, partition: part, into: into)
            sample_err = __se_extract_sample_error(summary)
            puts(
              "  partition=#{part.inspect} → status=#{summary.status} " \
              "docs=#{summary.docs_total} " \
              "failed=#{summary.failed_total} " \
              "batches=#{summary.batches_total} " \
              "duration_ms=#{summary.duration_ms_total}" \
              "#{sample_err ? " sample_error=#{sample_err.inspect}" : ''}"
            )
          end
        else
          summary = SearchEngine::Indexer.rebuild_partition!(self, partition: nil, into: into)
          sample_err = __se_extract_sample_error(summary)
          puts(
            "  single → status=#{summary.status} docs=#{summary.docs_total} " \
            "failed=#{summary.failed_total} batches=#{summary.batches_total} duration_ms=#{summary.duration_ms_total}" \
            "#{sample_err ? " sample_error=#{sample_err.inspect}" : ''}"
          )
        end
      end

      def __se_retention_cleanup!(logical:, client:)
        keep = begin
          local = respond_to?(:schema_retention) ? (schema_retention || {}) : {}
          lk = local[:keep_last]
          lk.nil? ? SearchEngine.config.schema.retention.keep_last : Integer(lk)
        rescue StandardError
          SearchEngine.config.schema.retention.keep_last
        end
        keep = 0 if keep.nil? || keep.to_i.negative?

        alias_target = client.resolve_alias(logical)
        names = Array(client.list_collections).map { |c| (c[:name] || c['name']).to_s }
        re = /^#{Regexp.escape(logical)}_\d{8}_\d{6}_\d{3}$/
        physicals = names.select { |n| re.match?(n) }

        ordered = physicals.sort_by do |n|
          ts = __se_extract_timestamp(logical, n)
          seq = __se_extract_sequence(n)
          [-ts, -seq]
        end

        candidates = ordered.reject { |n| n == alias_target }
        to_drop = candidates.drop(keep)
        to_drop.each { |n| client.delete_collection(n) }
        to_drop
      end

      def __se_extract_timestamp(logical, name)
        base = name.to_s.delete_prefix("#{logical}_")
        parts = base.split('_')
        return 0 unless parts.size == 3

        (parts[0] + parts[1]).to_i
      end

      def __se_extract_sequence(name)
        name.to_s.split('_').last.to_i
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

        # Build sets of hidden field names to strip from unknown attributes.
        begin
          attr_opts = respond_to?(:attribute_options) ? attribute_options : {}
        rescue StandardError
          attr_opts = {}
        end
        hidden_local = []
        attr_opts.each do |fname, opts|
          next unless opts.is_a?(Hash) && opts[:empty_filtering]

          hidden_local << "#{fname}_empty"
        end

        # For joined associations, hide $assoc.<field>_empty when target collection enabled it.
        hidden_join = []
        begin
          joins_cfg = self.class.respond_to?(:joins_config) ? self.class.joins_config : {}
          joins_cfg.each do |assoc_name, cfg|
            collection = cfg[:collection]
            next if collection.nil? || collection.to_s.strip.empty?

            begin
              target_klass = SearchEngine.collection_for(collection)
              next unless target_klass.respond_to?(:attribute_options)

              opts = target_klass.attribute_options || {}
              opts.each do |field_sym, o|
                next unless o.is_a?(Hash) && o[:empty_filtering]

                hidden_join << "$#{assoc_name}.#{field_sym}_empty"
              end
            rescue StandardError
              # Best-effort; skip when registry/metadata unavailable
            end
          end
        rescue StandardError
          # ignore
        end

        (doc || {}).each do |k, v|
          key_str = k.to_s
          key_sym = key_str.to_sym
          if declared.key?(key_sym)
            obj.instance_variable_set("@#{key_sym}", v)
          else
            # Strip hidden fields from unknowns
            next if hidden_local.include?(key_str)
            next if hidden_join.include?(key_str)

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

    # Return the document update timestamp coerced to Time.
    #
    # Prefers a declared attribute reader (when present). Falls back to the
    # unknown attributes payload (as returned by the backend) when the field
    # was not declared via the DSL. The value is coerced using the same logic
    # used for console rendering.
    #
    # @return [Time, nil]
    def doc_updated_at
      value = if instance_variable_defined?(:@doc_updated_at)
                instance_variable_get(:@doc_updated_at)
              else
                raw = instance_variable_get(:@__unknown_attributes__)
                if raw&.key?('doc_updated_at')
                  raw['doc_updated_at']
                elsif raw&.key?(:doc_updated_at)
                  raw[:doc_updated_at]
                end
              end

      return nil if value.nil?

      __se_coerce_doc_updated_at_for_display(value)
    rescue StandardError
      nil
    end

    # Return a symbol-keyed Hash of attributes for this record.
    #
    # - Includes declared attributes in declaration order
    # - Ensures :doc_updated_at is present and coerced to Time when available
    # - Includes unknown fields under :unknown_attributes (String-keyed), with
    #   "doc_updated_at" removed to avoid duplication
    #
    # @return [Hash{Symbol=>Object}]
    def attributes
      declared = begin
        self.class.respond_to?(:attributes) ? self.class.attributes : {}
      rescue StandardError
        {}
      end

      out = {}

      declared.each_key do |name|
        val = instance_variable_get("@#{name}")
        out[name] =
          if name.to_s == 'doc_updated_at' && !val.nil?
            __se_coerce_doc_updated_at_for_display(val)
          else
            val
          end
      end

      raw_unknowns = instance_variable_get(:@__unknown_attributes__)
      unknowns = raw_unknowns ? raw_unknowns.dup : {}

      unless out.key?(:doc_updated_at)
        raw_val = unknowns['doc_updated_at']
        raw_val = unknowns[:doc_updated_at] if raw_val.nil?
        out[:doc_updated_at] = __se_coerce_doc_updated_at_for_display(raw_val) unless raw_val.nil?
      end

      # Remove duplicate source of doc_updated_at from nested unknowns
      unknowns.delete('doc_updated_at')
      unknowns.delete(:doc_updated_at)

      out[:unknown_attributes] = unknowns unless unknowns.empty?
      out
    end

    # Human-friendly inspect that lists declared attributes and, when present,
    # unknown attributes captured during hydration.
    # @return [String]
    def inspect
      pairs = __attribute_pairs_for_render
      hex_id = begin
        # Mimic Ruby's default hex object id formatting
        format('0x%014x', object_id << 1)
      rescue StandardError
        object_id
      end
      attrs = pairs.map { |(k, v)| "#{k}: #{v.inspect}" }.join(', ')
      "#<#{self.class.name}:#{hex_id} #{attrs}>"
    end

    # Pretty-print with attributes on separate lines for readability in consoles.
    # Integrates with PP so arrays of models render multiline.
    # @param pp [PP]
    # @return [void]
    def pretty_print(pp)
      hex_id = begin
        format('0x%014x', object_id << 1)
      rescue StandardError
        object_id
      end
      pairs = __attribute_pairs_for_render
      pp.group(2, "#<#{self.class.name}:#{hex_id} ", '>') do
        pp.breakable ''
        pairs.each_with_index do |(k, v), idx|
          if v.is_a?(Array) || v.is_a?(Hash)
            pp.text("#{k}:")
            pp.nest(2) do
              pp.breakable ''
              pp.pp(v)
            end
          else
            pp.text("#{k}: ")
            pp.pp(v)
          end
          if idx < pairs.length - 1
            pp.text(',')
            pp.breakable ''
          end
        end
      end
    end

    private

    # Build ordered list of attribute pairs for rendering:
    # - Declared attributes in declaration order (with id rendered first when present)
    # - Followed by unknown attributes (when present)
    # @return [Array<[String, Object]>]
    def __attribute_pairs_for_render
      declared = begin
        self.class.respond_to?(:attributes) ? self.class.attributes : {}
      rescue StandardError
        {}
      end
      pairs = []

      # Render id first if declared
      if declared.key?(:id)
        id_val = instance_variable_get('@id')
        pairs << ['id', id_val]
      end

      declared.each_key do |name|
        next if name.to_s == 'id'

        value = instance_variable_get("@#{name}")
        pairs << if name.to_s == 'doc_updated_at' && !value.nil?
                   [name.to_s, __se_coerce_doc_updated_at_for_display(value)]
                 else
                   [name.to_s, value]
                 end
      end

      extras = unknown_attributes
      unless extras.empty?
        # If id wasn't declared but present in unknowns (e.g., no attribute declared), render it first
        if !declared.key?(:id) && (extras.key?('id') || extras.key?(:id))
          id_v = extras['id'] || extras[:id]
          pairs.unshift(['id', id_v])
        end

        passthrough, grouped, assoc_order = __se_group_join_fields_for_render(extras)

        # Render pass-through unknowns with special handling for doc_updated_at
        passthrough.each do |k, v|
          next if k.to_s == 'id' # already rendered first

          pairs <<
            if k.to_s == 'doc_updated_at' && !v.nil?
              [k.to_s, __se_coerce_doc_updated_at_for_display(v)]
            else
              pairs << [k.to_s, v]
            end
        end

        # Render grouped join fields as nested "$assoc => { field => value }"
        assoc_order.each do |assoc|
          pairs << [assoc.to_s, grouped[assoc]]
        end
      end
      # Fallback: ensure doc_updated_at is displayed when available via accessor
      # even if it wasn't declared and wasn't present in unknowns (e.g., selection omitted it).
      begin
        shown = pairs.any? { |(k, _)| k.to_s == 'doc_updated_at' }
        unless shown
          ts = doc_updated_at
          pairs << ['doc_updated_at', ts] unless ts.nil?
        end
      rescue StandardError
        # ignore display-only errors
      end
      pairs
    end

    # Group "$assoc.field" unknown attributes into a nested Hash under "$assoc" for rendering.
    # Prefers existing shapes when "$assoc" key already exists in the payload (Hash/Array).
    # Returns [passthrough(Map<key->val>), grouped(Map<assoc->Hash>), assoc_order(Array<String>)].
    def __se_group_join_fields_for_render(extras)
      grouped = {}
      assoc_order = []
      passthrough = {}

      extras.each do |k, v|
        key = k.to_s
        if key.start_with?('$') && key.include?('.') && !v.is_a?(Hash) && !v.is_a?(Array)
          assoc, field = key.split('.', 2)
          # Respect existing nested shape if present
          if extras.key?(assoc)
            passthrough[key] = v
          else
            unless grouped.key?(assoc)
              grouped[assoc] = {}
              assoc_order << assoc
            end
            grouped[assoc][field] = v
          end
        else
          passthrough[key] = v
        end
      end

      [passthrough, grouped, assoc_order]
    end

    # Convert integer epoch seconds to a Time in the current zone for display.
    # Falls back gracefully when value is not an Integer.
    def __se_coerce_doc_updated_at_for_display(value)
      int_val = begin
        Integer(value)
      rescue StandardError
        nil
      end
      return value if int_val.nil?

      if defined?(Time) && defined?(Time.zone) && Time.zone
        Time.zone.at(int_val)
      else
        Time.at(int_val)
      end
    rescue StandardError
      value
    end
  end
end
