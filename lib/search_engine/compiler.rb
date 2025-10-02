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
    # @param klass [Class] optional model class for future type hints (unused)
    # @return [String]
    def compile(ast, klass: nil) # rubocop:disable Lint/UnusedMethodArgument
      root = coerce_root(ast)
      return '' unless root

      compile_node(root, parent_prec: 0)
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
        binary(node.field, ':=', quote(node.value))
      when SearchEngine::AST::NotEq
        binary(node.field, ':!=', quote(node.value))
      when SearchEngine::AST::Gt
        binary(node.field, ':>', quote(node.value))
      when SearchEngine::AST::Gte
        binary(node.field, ':>=', quote(node.value))
      when SearchEngine::AST::Lt
        binary(node.field, ':<', quote(node.value))
      when SearchEngine::AST::Lte
        binary(node.field, ':<=', quote(node.value))
      when SearchEngine::AST::In
        binary(node.field, ':=', quote(node.values))
      when SearchEngine::AST::NotIn
        binary(node.field, ':!=', quote(node.values))
      when SearchEngine::AST::And
        compile_boolean(node.children, ' && ', parent_prec: parent_prec, my_prec: precedence(:and))
      when SearchEngine::AST::Or
        # For clarity, always parenthesize right-hand child when it is an AND or a grouped expression
        compiled = compile_boolean(node.children, ' || ', parent_prec: parent_prec, my_prec: precedence(:or))
        # If the rightmost child is an And node and not already grouped, ensure parentheses
        if node.children.length == 2 && node.children.last.is_a?(SearchEngine::AST::And)
          left_str, right_str = compiled.split(' || ', 2)
          compiled = "#{left_str} || (#{right_str})"
        end
        compiled
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
  end
end
