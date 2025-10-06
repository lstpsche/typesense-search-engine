# frozen_string_literal: true

module SearchEngine
  class Relation
    module DSL
      # Filter-related chainers and normalizers.
      # These methods are mixed into Relation's DSL and must preserve copy-on-write semantics.
      module Filters
        # Add filters to the relation.
        # @param args [Array<Object>] filter arguments
        # @return [SearchEngine::Relation]
        def where(*args)
          ast_nodes = SearchEngine::DSL::Parser.parse_list(args, klass: @klass, joins: joins_list)
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
              validate_hash_keys!(entry, known_attrs)
              fragments.concat(SearchEngine::Filters::Sanitizer.build_from_hash(entry, known_attrs))
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
