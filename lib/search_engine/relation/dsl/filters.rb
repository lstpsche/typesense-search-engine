# frozen_string_literal: true

module SearchEngine
  class Relation
    module DSL
      # Filter-related chainers and normalizers.
      # These methods are mixed into Relation's DSL and must preserve copy-on-write semantics.
      module Filters
        # AR-style where.not support via a small chain proxy.
        class WhereChain
          def initialize(relation)
            @relation = relation
          end

          # Replace positive predicates with negated form.
          # Supports Hash, String templates, Arrays (delegated to parser with a negation flag).
          # @param args [Array<Object>]
          # @return [SearchEngine::Relation]
          def not(*args)
            nodes = Array(@relation.send(:build_ast_with_empty_array_rewrites, args, negated: true))

            # Invert non-hidden predicates (Eq, In) returned by the builder
            negated = nodes.map do |node|
              case node
              when SearchEngine::AST::Eq
                SearchEngine::AST.not_eq(node.field, node.value)
              when SearchEngine::AST::In
                SearchEngine::AST.not_in(node.field, node.values)
              else
                node
              end
            end

            @relation.send(:spawn) do |s|
              s[:ast] = Array(s[:ast]) + negated
              s[:filters] = Array(s[:filters])
            end
          end
        end

        # Add filters to the relation.
        # When called without arguments, returns a WhereChain for `.where.not(...)` style.
        # @param args [Array<Object>] filter arguments
        # @return [SearchEngine::Relation, WhereChain]
        def where(*args)
          return self if args.nil? || args.empty?

          ast_nodes = build_ast_with_empty_array_rewrites(args, negated: false)
          fragments = normalize_where(args)
          spawn do |s|
            s[:ast] = Array(s[:ast]) + Array(ast_nodes)
            s[:filters] = Array(s[:filters]) + fragments
          end
        end

        # Replace all predicates with a new where input.
        # @param input [Hash, String, Array, Symbol]
        # @param args [Array<Object>]
        # @return [SearchEngine::Relation]
        def rewhere(input, *args)
          if input.nil? || (input.respond_to?(:empty?) && input.empty?) || (input.is_a?(String) && input.strip.empty?)
            raise ArgumentError, 'rewhere: provide a new predicate input'
          end

          nodes = SearchEngine::DSL::Parser.parse(input, klass: @klass, args: args, joins: joins_list)
          list = Array(nodes).flatten.compact
          raise ArgumentError, 'rewhere: produced no predicates' if list.empty?

          spawn do |s|
            s[:ast] = list
            s[:filters] = []
          end
        end

        private

        # Build AST nodes, rewriting empty-array predicates to hidden *_empty flags when enabled.
        # Delegates other inputs to the DSL parser.
        def build_ast_with_empty_array_rewrites(args, negated: false)
          items = Array(args).flatten.compact
          return [] if items.empty?

          out_nodes = []
          non_hash_items = []

          items.each do |entry|
            if entry.is_a?(Hash)
              process_hash_entry(entry, out_nodes, negated)
            else
              non_hash_items << entry
            end
          end

          unless non_hash_items.empty?
            out_nodes.concat(
              Array(SearchEngine::DSL::Parser.parse_list(non_hash_items, klass: @klass, joins: joins_list))
            )
          end

          out_nodes.flatten.compact
        end

        def process_hash_entry(entry, out_nodes, negated)
          entry.each do |k, v|
            if v.is_a?(Hash)
              process_join_predicate(k, v, out_nodes, negated)
            else
              process_base_predicate(k, v, out_nodes, negated)
            end
          end
        end

        def process_join_predicate(assoc_key, values_hash, out_nodes, negated)
          assoc = assoc_key.to_sym
          values_hash.each do |inner_field, inner_value|
            field_sym = inner_field.to_sym
            if array_like?(inner_value)
              arr = Array(inner_value).flatten(1).compact
              if arr.empty?
                if joined_empty_filtering_enabled?(assoc, field_sym)
                  emit_empty_array_flag(out_nodes, "$#{assoc}.#{field_sym}_empty", negated)
                else
                  raise_empty_array_type!(field_sym)
                end
              else
                out_nodes << SearchEngine::DSL::Parser.parse(
                  { assoc => { field_sym => inner_value } }, klass: @klass, joins: joins_list
                )
              end
            else
              out_nodes << SearchEngine::DSL::Parser.parse(
                { assoc => { field_sym => inner_value } }, klass: @klass, joins: joins_list
              )
            end
          end
        end

        def process_base_predicate(field_key, value, out_nodes, negated)
          field = field_key.to_sym
          if array_like?(value)
            arr = Array(value).flatten(1).compact
            if arr.empty?
              if base_empty_filtering_enabled?(field)
                emit_empty_array_flag(out_nodes, "#{field}_empty", negated)
              else
                raise_empty_array_type!(field)
              end
            else
              out_nodes << SearchEngine::DSL::Parser.parse({ field => value }, klass: @klass, joins: joins_list)
            end
          else
            out_nodes << SearchEngine::DSL::Parser.parse({ field => value }, klass: @klass, joins: joins_list)
          end
        end

        def emit_empty_array_flag(out_nodes, lhs, negated)
          out_nodes << SearchEngine::AST.raw("#{lhs}:=#{negated ? 'false' : 'true'}")
        end

        def base_empty_filtering_enabled?(field_sym)
          opts = @klass.respond_to?(:attribute_options) ? (@klass.attribute_options || {}) : {}
          o = opts[field_sym]
          o.is_a?(Hash) && o[:empty_filtering]
        rescue StandardError
          false
        end

        def joined_empty_filtering_enabled?(assoc_sym, field_sym)
          cfg = @klass.join_for(assoc_sym)
          collection = cfg[:collection]
          return false if collection.nil? || collection.to_s.strip.empty?

          target_klass = SearchEngine.collection_for(collection)
          return false unless target_klass.respond_to?(:attribute_options)

          o = (target_klass.attribute_options || {})[field_sym]
          o.is_a?(Hash) && o[:empty_filtering]
        rescue StandardError
          false
        end

        def array_like?(value)
          value.is_a?(Array)
        end

        def raise_empty_array_type!(field_sym)
          raise SearchEngine::Errors::InvalidType.new(
            %(expected #{field_sym.inspect} to be a non-empty Array),
            doc: 'docs/query_dsl.md#troubleshooting',
            details: { field: field_sym }
          )
        end

        # Normalize where arguments into an array of string fragments safe for Typesense.
        def normalize_where(args)
          list = Array(args).flatten.compact
          return [] if list.empty?

          fragments = []
          i = 0
          known_attrs = safe_attributes_map

          while i < list.length
            entry = list[i]
            case entry
            when Hash
              # Validate only base keys here; assoc keys (values as Hash) are handled via AST/Parser
              validate_hash_keys!(entry, known_attrs)
              # Build fragments from base scalar/array pairs only; skip assoc=>{...}
              base_pairs = entry.reject { |_, v| v.is_a?(Hash) }
              unless base_pairs.empty?
                fragments.concat(
                  SearchEngine::Filters::Sanitizer.build_from_hash(base_pairs, known_attrs)
                )
              end
              i += 1
            when String
              i = normalize_where_process_string!(fragments, entry, list, i)
            when Symbol
              fragments << entry.to_s
              i += 1
            when Array
              nested = normalize_where(entry)
              fragments.concat(nested)
              i += 1
            else
              raise ArgumentError, "unsupported where argument of type #{entry.class}"
            end
          end

          fragments
        end

        def normalize_where_process_string!(fragments, entry, list, i)
          if entry.match?(/(?<!\\)\?/) # has unescaped placeholders
            tail = list[(i + 1)..] || []
            needed = SearchEngine::Filters::Sanitizer.count_placeholders(entry)
            args_for_template = tail.first(needed)
            if args_for_template.length != needed
              raise ArgumentError, "expected #{needed} args for #{needed} placeholders, got #{args_for_template.length}"
            end

            fragments << SearchEngine::Filters::Sanitizer.apply_placeholders(entry, args_for_template)
            i + 1 + needed
          else
            fragments << entry.to_s
            i + 1
          end
        end
      end
    end
  end
end
