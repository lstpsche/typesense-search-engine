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

    # Add filters in a normalized form.
    # Accepts Hash, String/Symbol, or Arrays of these.
    # @return [SearchEngine::Relation]
    def where(*args)
      fragments = normalize_where(args)
      spawn do |s|
        s[:filters] = Array(s[:filters]) + fragments
      end
    end

    # Append ordering expressions. Accepts Symbol/String/Hash or Array of these.
    # @param clause [Object]
    # @return [SearchEngine::Relation]
    def order(clause)
      additions = normalize_order(clause)
      spawn do |s|
        s[:orders] = Array(s[:orders]) + additions
      end
    end

    # Select a subset of fields. De-duplicates and preserves order.
    # @param fields [Array<#to_sym,#to_s>]
    # @return [SearchEngine::Relation]
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
    def limit(n)
      value = coerce_non_negative_integer(n, :limit)
      spawn { |s| s[:limit] = value }
    end

    # Set the offset of results.
    # @param n [Integer, #to_i, nil]
    # @return [SearchEngine::Relation]
    def offset(n)
      value = coerce_non_negative_integer(n, :offset)
      spawn { |s| s[:offset] = value }
    end

    # Set page number.
    # @param n [Integer, #to_i, nil]
    # @return [SearchEngine::Relation]
    def page(n)
      value = coerce_non_negative_integer(n, :page)
      spawn { |s| s[:page] = value }
    end

    # Set per-page size.
    # @param n [Integer, #to_i, nil]
    # @return [SearchEngine::Relation]
    def per_page(n)
      value = coerce_non_negative_integer(n, :per_page)
      spawn { |s| s[:per_page] = value }
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

    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
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
      return {} if state.blank?
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
        when :limit, :offset, :page, :per_page
          normalized[k] = coerce_non_negative_integer(value, k)
        when :options
          normalized[:options] = (value || {}).dup
        end
      end
      normalized
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    def normalize_where(args)
      Array(args).flatten.compact.flat_map do |arg|
        case arg
        when Hash
          arg.each_pair.map { |k, v| { field: k.to_sym, op: :eq, value: v } }
        when String, Symbol
          [{ raw: arg.to_s }]
        else
          [arg]
        end
      end
    end

    def normalize_order(clause) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
      return [] if clause.nil?

      list = Array(clause).flatten.compact
      list.flat_map do |entry|
        case entry
        when Hash
          entry.map do |k, dir|
            direction = dir.to_s.downcase
            direction = %w[asc desc].include?(direction) ? direction : 'asc'
            { field: k.to_sym, direction: direction.to_sym }
          end
        when Symbol
          [{ field: entry, direction: :asc }]
        when String
          if entry.include?(' ')
            name, dir = entry.split(' ', 2)
            direction = dir.to_s.strip.downcase
            direction = %w[asc desc].include?(direction) ? direction : 'asc'
            [{ field: name.to_sym, direction: direction.to_sym }]
          else
            [{ field: entry.to_sym, direction: :asc }]
          end
        else
          [entry]
        end
      end
    end

    def normalize_select(fields)
      ordered = Array(fields).flatten.compact.map do |f|
        f.respond_to?(:to_sym) ? f.to_sym : f.to_s
      end
      ordered.each_with_object([]) do |f, acc|
        acc << f unless acc.include?(f)
      end
    end

    def coerce_non_negative_integer(value, name)
      return nil if value.nil?

      integer =
        case value
        when Integer then value
        else Integer(value)
        end
      raise ArgumentError, "#{name} must be non-negative" if integer.negative?

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
  end
end
