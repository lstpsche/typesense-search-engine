module SearchEngine
  # Immutable, chainable query relation bound to a model class.
  #
  # Carries normalized query state and provides copy-on-write chainers.
  # All chainers return new frozen instances; no in-place mutation occurs.
  #
  # @example Basic chaining
  #   class Product < SearchEngine::Base; end
  #   r1 = Product.all
  #   r2 = r1.where(category: 'milk').order(:name).limit(10)
  #   r1.object_id != r2.object_id #=> true
  #   r1.empty?                    #=> true
  class Relation
    # Internal normalized state keys
    DEFAULT_STATE = {
      filters: [].freeze,
      orders:  [].freeze,
      select:  [].freeze,
      limit:   nil,
      offset:  nil,
      page:    nil,
      per_page: nil,
      options: {}.freeze
    }.freeze

    # @return [Class] bound model class (typically a SearchEngine::Base subclass)
    attr_reader :klass

    # Create a new Relation.
    #
    # @param klass [Class] model class the relation is bound to
    # @param state [Hash] optional pre-populated normalized state
    def initialize(klass, state = {})
      @klass = klass
      normalized = normalize_initial_state(state)
      @state = DEFAULT_STATE.merge(normalized)
      deep_freeze_inplace(@state)
    end

    # Return self for AR-like parity.
    # @return [SearchEngine::Relation]
    def all
      self
    end

    # Add filters to the relation.
    #
    # Accepted forms:
    # - Hash: where(id: 1, brand_id: [1,2,3])
    # - Raw string fragment: where("brand_id:=[1,2,3]")
    # - Template with placeholders: where("price > ?", 100)
    #
    # Multiple calls compose with AND semantics (filters accumulate).
    # The relation is immutable; a new instance is returned.
    #
    # @param args [Array<Object>] filter arguments
    # @return [SearchEngine::Relation]
    def where(*args)
      fragments = normalize_where(args)
      spawn do |s|
        s[:filters] = Array(s[:filters]) + fragments
      end
    end

    # Append ordering expressions. Accepts Hash or String forms.
    #
    # Accepted input:
    # - Hash: { field => :asc|:desc, ... }
    # - String: "field:dir" or comma-separated "field:dir,other:asc"
    #
    # Normalization:
    # - Stored as array of strings like ["field:asc", "other:desc"]
    # - Direction lowercased; field trimmed; validation enforced
    # - Dedupe by field with last-wins semantics while preserving last position
    #
    # @param value [Hash, String]
    # @return [SearchEngine::Relation]
    # @raise [ArgumentError] when direction or field is invalid
    def order(value)
      additions = normalize_order(value)
      spawn do |s|
        existing = Array(s[:orders])
        s[:orders] = dedupe_orders_last_wins(existing + additions)
      end
    end

    # Select a subset of fields. De-duplicates and preserves order of first appearance.
    #
    # @param fields [Array<#to_sym,#to_s>]
    # @return [SearchEngine::Relation]
    # @raise [ArgumentError] when fields are blank or unknown for the model
    def select(*fields)
      normalized = normalize_select(fields)
      spawn do |s|
        existing = Array(s[:select])
        s[:select] = (existing + normalized).each_with_object([]) do |f, acc|
          acc << f unless acc.include?(f)
        end
      end
    end

    # Set the maximum number of results.
    # @param n [Integer, #to_i, nil]
    # @return [SearchEngine::Relation]
    # @raise [ArgumentError] when n < 1 or not coercible to Integer
    def limit(n)
      value = coerce_integer_min(n, :limit, 1)
      spawn { |s| s[:limit] = value }
    end

    # Set the offset of results.
    # @param n [Integer, #to_i, nil]
    # @return [SearchEngine::Relation]
    # @raise [ArgumentError] when n < 0 or not coercible to Integer
    def offset(n)
      value = coerce_integer_min(n, :offset, 0)
      spawn { |s| s[:offset] = value }
    end

    # Set page number.
    # @param n [Integer, #to_i, nil]
    # @return [SearchEngine::Relation]
    # @raise [ArgumentError] when n < 1 or not coercible to Integer
    def page(n)
      value = coerce_integer_min(n, :page, 1)
      spawn { |s| s[:page] = value }
    end

    # Set per-page size.
    # @param n [Integer, #to_i, nil]
    # @return [SearchEngine::Relation]
    # @raise [ArgumentError] when n < 1 or not coercible to Integer
    def per_page(n)
      value = coerce_integer_min(n, :per, 1)
      spawn { |s| s[:per_page] = value }
    end

    # Convenience alias for per-page size.
    # @param n [Integer, #to_i, nil]
    # @return [SearchEngine::Relation]
    def per(n)
      per_page(n)
    end

    # Shallow-merge options into the relation.
    # For nested hashes, merging is shallow by default.
    # @param opts [Hash]
    # @return [SearchEngine::Relation]
    def options(opts = {})
      raise ArgumentError, 'options must be a Hash' unless opts.is_a?(Hash)

      spawn do |s|
        s[:options] = (s[:options] || {}).merge(opts)
      end
    end

    # True when the relation has no accumulated state beyond defaults.
    # @return [Boolean]
    def empty?
      @state == DEFAULT_STATE
    end

    # Concise single-line inspection containing only non-empty keys.
    # @return [String]
    def inspect
      parts = []
      parts << "klass=#{klass_name_for_inspect}"
      DEFAULT_STATE.each_key do |key|
        value = @state[key]
        next if value == DEFAULT_STATE[key]

        parts << "#{key}=#{format_value_for_inspect(value)}"
      end
      "#<#{self.class.name} #{parts.join(' ')} >"
    end

    protected

    # Spawn a new relation with a deep-duplicated mutable state.
    # The given block may mutate the provided state Hash (shallow mutations only).
    # Returns a new frozen Relation.
    # @yieldparam state [Hash]
    # @return [SearchEngine::Relation]
    def spawn
      mutable_state = deep_dup(@state)
      yield mutable_state
      self.class.new(@klass, mutable_state)
    end

    private

    def klass_name_for_inspect
      @klass.respond_to?(:name) && @klass.name ? @klass.name : @klass.to_s
    end

    # rubocop:disable Metrics/PerceivedComplexity
    def format_value_for_inspect(value)
      case value
      when Array
        return '[]' if value.empty?

        if value.length <= 3
          value.inspect
        else
          head = value.first(3).map(&:inspect).join(', ')
          "[#{head}... +#{value.length - 3}]"
        end
      when Hash
        return '{}' if value.empty?

        keys = value.keys
        if keys.length <= 3
          value.inspect
        else
          head = keys.first(3).map(&:inspect).join(', ')
          "{#{head}... +#{keys.length - 3} keys}"
        end
      else
        value.inspect
      end
    end
    # rubocop:enable Metrics/PerceivedComplexity

    def normalize_initial_state(state)
      return {} if state.nil? || state.empty?
      raise ArgumentError, 'state must be a Hash' unless state.is_a?(Hash)

      normalized = {}
      state.each do |key, value|
        k = key.to_sym
        case k
        when :filters
          normalized[:filters] = normalize_where(Array(value))
        when :orders
          normalized[:orders] = normalize_order(value)
        when :select
          normalized[:select] = normalize_select(Array(value))
        when :limit
          normalized[:limit] = coerce_integer_min(value, :limit, 1)
        when :offset
          normalized[:offset] = coerce_integer_min(value, :offset, 0)
        when :page
          normalized[:page] = coerce_integer_min(value, :page, 1)
        when :per_page
          normalized[:per_page] = coerce_integer_min(value, :per, 1)
        when :options
          normalized[:options] = (value || {}).dup
        end
      end
      normalized
    end

    # Normalize where arguments into an array of string fragments safe for Typesense.
    # Supports hash, raw string, and template-with-placeholders.
    def normalize_where(args) # rubocop:disable Metrics/PerceivedComplexity
      list = Array(args).flatten.compact
      return [] if list.empty?

      fragments = []
      i = 0
      known_attrs = safe_attributes_map

      while i < list.length
        entry = list[i]
        case entry
        when Hash
          validate_hash_keys!(entry, known_attrs)
          fragments.concat(SearchEngine::Filters::Sanitizer.build_from_hash(entry, known_attrs))
          i += 1
        when String
          if entry.match?(/(?<!\\)\?/) # has unescaped placeholders
            tail = list[(i + 1)..] || []
            needed = SearchEngine::Filters::Sanitizer.count_placeholders(entry)
            args_for_template = tail.first(needed)
            if args_for_template.length != needed # rubocop:disable Metrics/BlockNesting
              raise ArgumentError, "expected #{needed} args for #{needed} placeholders, got #{args_for_template.length}"
            end

            fragments << SearchEngine::Filters::Sanitizer.apply_placeholders(entry, args_for_template)
            i += 1 + needed
          else
            fragments << entry.to_s
            i += 1
          end
        when Symbol
          # Treat symbol as raw string fragment for compatibility
          fragments << entry.to_s
          i += 1
        when Array
          # Recurse over nested arrays
          nested = normalize_where(entry)
          fragments.concat(nested)
          i += 1
        else
          raise ArgumentError, "unsupported where argument of type #{entry.class}"
        end
      end

      fragments
    end

    # Parse and normalize order input into an array of "field:dir" strings.
    def normalize_order(value) # rubocop:disable Metrics/PerceivedComplexity
      return [] if value.nil?

      case value
      when Hash
        value.flat_map do |k, dir|
          field = k.to_s.strip
          raise ArgumentError, 'order: field name must be non-empty' if field.empty?

          direction = dir.to_s.strip.downcase
          unless %w[asc desc].include?(direction)
            raise ArgumentError, "order: direction must be :asc or :desc (got #{dir.inspect} for field #{k.inspect})"
          end

          "#{field}:#{direction}"
        end
      when String
        value.split(',').map(&:strip).reject(&:empty?).map do |chunk|
          name, direction = chunk.split(':', 2).map { |p| p.to_s.strip }
          if name.empty? || direction.empty?
            raise ArgumentError, "order: expected 'field:direction' (got #{chunk.inspect})"
          end

          downcased = direction.downcase
          unless %w[asc desc].include?(downcased)
            raise ArgumentError,
                  "order: direction must be :asc or :desc (got #{direction.inspect} for field #{name.inspect})"
          end

          "#{name}:#{downcased}"
        end
      when Array
        # Allow arrays of accepted forms
        value.flat_map { |v| normalize_order(v) }
      when Symbol
        # Back-compat: treat as ascending
        field = value.to_s.strip
        raise ArgumentError, 'order: field name must be non-empty' if field.empty?

        ["#{field}:asc"]
      else
        raise ArgumentError, "order: unsupported input #{value.class}"
      end
    end

    # Dedupe by field with last-wins semantics while preserving last positions.
    def dedupe_orders_last_wins(list)
      return [] if list.nil? || list.empty?

      last_by_field = {}
      list.each_with_index do |entry, idx|
        field, dir = entry.split(':', 2)
        last_by_field[field] = { idx: idx, str: "#{field}:#{dir}" }
      end
      last_by_field.values.sort_by { |h| h[:idx] }.map { |h| h[:str] }
    end

    def normalize_select(fields)
      list = Array(fields).flatten.compact
      return [] if list.empty?

      known_attrs = safe_attributes_map
      known = known_attrs.keys.map(&:to_s)

      ordered = []
      list.each do |f|
        name = f.to_s.strip
        raise ArgumentError, 'select: field names must be non-empty' if name.empty?

        if !known.empty? && !known.include?(name)
          klass_name = klass_name_for_inspect
          known_list = known.sort.join(', ')
          raise ArgumentError, "select: unknown field #{name.inspect} for #{klass_name}. Known: #{known_list}"
        end

        ordered << name unless ordered.include?(name)
      end
      ordered
    end

    def coerce_integer_min(value, name, min)
      return nil if value.nil?

      integer =
        case value
        when Integer then value
        else Integer(value)
        end

      raise ArgumentError, "#{name} must be >= #{min}" if integer < min

      integer
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be an Integer or nil"
    end

    def deep_dup(obj)
      case obj
      when Hash
        obj.transform_values(&method(:deep_dup))
      when Array
        obj.map(&method(:deep_dup))
      else
        obj
      end
    end

    def deep_freeze_inplace(obj)
      case obj
      when Hash
        obj.each_value { |v| deep_freeze_inplace(v) }
        obj.freeze
      when Array
        obj.each { |el| deep_freeze_inplace(el) }
        obj.freeze
      else
        obj.freeze if obj.is_a?(String)
      end
      obj
    end

    def safe_attributes_map
      if @klass.respond_to?(:attributes)
        @klass.attributes || {}
      else
        {}
      end
    end

    def validate_hash_keys!(hash, attributes_map)
      return if hash.nil? || hash.empty?

      known = attributes_map.keys.map(&:to_sym)
      unknown = hash.keys.map(&:to_sym) - known
      return if unknown.empty?

      klass_name = klass_name_for_inspect
      known_list = known.map(&:to_s).sort.join(', ')
      unknown_name = unknown.first.inspect
      raise ArgumentError, "Unknown attribute #{unknown_name} for #{klass_name}. Known: #{known_list}"
    end
  end
end
