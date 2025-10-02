# frozen_string_literal: true

require 'search_engine/filters/sanitizer'
require 'search_engine/ast'

module SearchEngine
  # Compiler for turning Predicate AST into Typesense `filter_by` strings.
  #
  # Pure and deterministic: no side effects, no I/O. Uses
  # `SearchEngine::Filters::Sanitizer` for all quoting/escaping to ensure
  # consistent rendering with the `where` DSL.
  module Compiler
    class Error < StandardError; end
    class UnsupportedNode < Error; end

    module_function

    # Compile an AST node or an array of nodes (implicit AND) into a Typesense
    # `filter_by` string.
    #
    # - Nil or empty input returns an empty String
    # - Arrays at the top-level are treated as implicit AND
    # - Group nodes are always parenthesized
    # - Raw fragments are passed-through
    #
    # @param ast [SearchEngine::AST::Node, Array<SearchEngine::AST::Node>, nil]
    # @param klass [Class] optional model class for context (used for observability)
    # @return [String]
    # @note Emits "search_engine.compile" via ActiveSupport::Notifications with
    #   payload: { collection, klass, node_count, duration_ms, source: :ast }
    def compile(ast, klass: nil)
      root = coerce_root(ast)
      return '' unless root

      compiled = nil
      if defined?(ActiveSupport::Notifications)
        start_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
        payload = {
          collection: safe_collection_for_klass(klass),
          klass: safe_klass_name(klass),
          node_count: count_nodes(root),
          duration_ms: nil,
          source: :ast
        }
        ActiveSupport::Notifications.instrument('search_engine.compile', payload) do
          compiled = compile_node(root, parent_prec: 0)
          payload[:duration_ms] = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - start_ms
        end
        compiled
      else
        compile_node(root, parent_prec: 0)
      end
    end

    # --- Internals ---------------------------------------------------------

    def coerce_root(ast)
      return nil if ast.nil?

      if ast.is_a?(Array)
        nodes = ast.flatten.compact.select { |n| n.is_a?(SearchEngine::AST::Node) }
        return nil if nodes.empty?
        return nodes.first if nodes.length == 1

        return SearchEngine::AST.and_(*nodes)
      end

      return ast if ast.is_a?(SearchEngine::AST::Node)

      raise Error, "Compiler: unsupported root input #{ast.class}"
    end
    private_class_method :coerce_root

    def compile_node(node, parent_prec:)
      case node
      when SearchEngine::AST::Eq
        compile_binary(node.field, ':=', node.value)
      when SearchEngine::AST::NotEq
        compile_binary(node.field, ':!=', node.value)
      when SearchEngine::AST::Gt
        compile_binary(node.field, ':>', node.value)
      when SearchEngine::AST::Gte
        compile_binary(node.field, ':>=', node.value)
      when SearchEngine::AST::Lt
        compile_binary(node.field, ':<', node.value)
      when SearchEngine::AST::Lte
        compile_binary(node.field, ':<=', node.value)
      when SearchEngine::AST::In
        compile_binary(node.field, ':=', node.values)
      when SearchEngine::AST::NotIn
        compile_binary(node.field, ':!=', node.values)
      when SearchEngine::AST::And
        compile_boolean(node.children, ' && ', parent_prec: parent_prec, my_prec: precedence(:and))
      when SearchEngine::AST::Or
        compile_or(node, parent_prec)
      when SearchEngine::AST::Group
        "(#{compile_node(node.children.first, parent_prec: 0)})"
      when SearchEngine::AST::Raw
        node.fragment
      when SearchEngine::AST::Matches
        raise UnsupportedNode, 'Typesense filter_by does not support MATCHES; use AST::Raw if needed.'
      when SearchEngine::AST::Prefix
        raise UnsupportedNode, 'Typesense filter_by does not support PREFIX; use AST::Raw if needed.'
      else
        raise Error, "Compiler: unknown node #{node.class}"
      end
    end
    private_class_method :compile_node

    def compile_or(node, parent_prec)
      compiled = compile_boolean(node.children, ' || ', parent_prec: parent_prec, my_prec: precedence(:or))
      if node.children.length == 2 && node.children.last.is_a?(SearchEngine::AST::And)
        left_str, right_str = compiled.split(' || ', 2)
        compiled = "#{left_str} || (#{right_str})"
      end
      compiled
    end
    private_class_method :compile_or

    def compile_binary(field, op, value)
      binary(field, op, quote(value))
    end
    private_class_method :compile_binary

    def binary(field, op, rhs)
      "#{field}#{op}#{rhs}"
    end
    private_class_method :binary

    def compile_boolean(children, joiner, parent_prec:, my_prec:)
      parts = children.map do |child|
        cstr = compile_node(child, parent_prec: my_prec)
        if needs_parentheses?(child, parent_prec: my_prec)
          "(#{cstr})"
        else
          cstr
        end
      end
      inner = parts.join(joiner)

      # Parent adds parens if its precedence is greater than ours
      if parent_prec > my_prec
        "(#{inner})"
      else
        inner
      end
    end
    private_class_method :compile_boolean

    def quote(value)
      SearchEngine::Filters::Sanitizer.quote(value)
    end
    private_class_method :quote

    def needs_parentheses?(child, parent_prec:)
      child_prec = precedence(child)
      # Parenthesize when child binds looser than parent
      child_prec < parent_prec
    end
    private_class_method :needs_parentheses?

    def precedence(node)
      case node
      when Symbol
        return 20 if node == :and
        return 10 if node == :or

        100
      when SearchEngine::AST::And
        20
      when SearchEngine::AST::Or
        10
      when SearchEngine::AST::Group
        # Group is a special case; caller always wraps it explicitly
        100
      else
        # Leaves (Eq, In, etc.) bind tight
        100
      end
    end
    private_class_method :precedence

    def count_nodes(node)
      return 0 unless node.is_a?(SearchEngine::AST::Node)

      1 + Array(node.children).sum { |child| count_nodes(child) }
    end
    private_class_method :count_nodes

    def safe_klass_name(klass)
      return nil unless klass

      klass.respond_to?(:name) && klass.name ? klass.name : klass.to_s
    end
    private_class_method :safe_klass_name

    def safe_collection_for_klass(klass)
      return nil unless klass
      return klass.collection if klass.respond_to?(:collection) && klass.collection

      nil
    end
    private_class_method :safe_collection_for_klass
  end
end
