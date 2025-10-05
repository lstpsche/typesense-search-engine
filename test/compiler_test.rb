# frozen_string_literal: true

require 'test_helper'

class CompilerTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_compiler'
    attribute :id, :integer
    attribute :name, :string
    attribute :active, :boolean
    attribute :price, :float
    attribute :brand_id, :integer
    attribute :created_at, :time
  end

  def compile(ast)
    SearchEngine::Compiler.compile(ast, klass: Product)
  end

  def test_binary_comparisons
    assert_equal 'id:=1', compile(SearchEngine::AST.eq(:id, 1))
    assert_equal 'price:>100', compile(SearchEngine::AST.gt(:price, 100))
    assert_equal 'price:>=100', compile(SearchEngine::AST.gte(:price, 100))
    assert_equal 'price:<10', compile(SearchEngine::AST.lt(:price, 10))
    assert_equal 'price:<=10', compile(SearchEngine::AST.lte(:price, 10))
    assert_equal 'active:!=false', compile(SearchEngine::AST.not_eq(:active, false))
  end

  def test_in_and_not_in
    assert_equal 'brand_id:=[1, 2]', compile(SearchEngine::AST.in_(:brand_id, [1, 2]))
    assert_equal 'brand_id:!=[1, 2]', compile(SearchEngine::AST.not_in(:brand_id, [1, 2]))
  end

  def test_quoting_and_types
    assert_equal 'name:="mil\"k"', compile(SearchEngine::AST.eq(:name, 'mil"k'))
    assert_equal 'active:=true', compile(SearchEngine::AST.eq(:active, true))
    assert_equal 'active:=false', compile(SearchEngine::AST.eq(:active, false))
    assert_equal 'name:=["a", "b"]', compile(SearchEngine::AST.in_(:name, %w[a b]))
    assert_equal 'id:=null', compile(SearchEngine::AST.eq(:id, nil))

    t = Time.utc(2020, 1, 1, 12, 0, 0)
    assert_equal 'created_at:="2020-01-01T12:00:00Z"', compile(SearchEngine::AST.eq(:created_at, t))
  end

  def test_boolean_composition_and_parentheses
    a = SearchEngine::AST.eq(:a, 1)
    b = SearchEngine::AST.eq(:b, 2)
    c = SearchEngine::AST.eq(:c, 3)

    and_node = SearchEngine::AST.and_(a, b)
    or_node  = SearchEngine::AST.or_(a, b)

    assert_equal 'a:=1 && b:=2', compile(and_node)
    assert_equal 'a:=1 || b:=2', compile(or_node)

    mixed = SearchEngine::AST.or_(a, SearchEngine::AST.and_(b, c))
    assert_equal 'a:=1 || (b:=2 && c:=3)', compile(mixed)

    grouped = SearchEngine::AST.group(or_node)
    assert_equal '(a:=1 || b:=2)', compile(grouped)
  end

  def test_top_level_array_is_implicit_and
    asts = [SearchEngine::AST.eq(:x, 1), SearchEngine::AST.eq(:y, 2)]
    assert_equal 'x:=1 && y:=2', compile(asts)
  end

  def test_raw_passthrough
    raw = SearchEngine::AST.raw('price:>100 && active:=true')
    assert_equal 'price:>100 && active:=true', compile(raw)
  end

  def test_unsupported_nodes_raise
    assert_raises(SearchEngine::Compiler::UnsupportedNode) do
      compile(SearchEngine::AST.matches(:name, 'mil.*'))
    end
    assert_raises(SearchEngine::Compiler::UnsupportedNode) do
      compile(SearchEngine::AST.prefix(:name, 'mil'))
    end
  end

  def test_determinism_no_trailing_spaces
    node = SearchEngine::AST.and_(SearchEngine::AST.eq(:a, 1), SearchEngine::AST.eq(:b, 2))
    s_1 = compile(node)
    s_2 = compile(node)
    assert_equal s_1, s_2
    refute_match(/\s\z/, s_1)
  end
end
