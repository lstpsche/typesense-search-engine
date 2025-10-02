# frozen_string_literal: true

require 'minitest/autorun'
require 'search_engine/ast'

class ASTTest < Minitest::Test
  def test_eq_node_immutability_and_accessors
    n = SearchEngine::AST.eq(:price, 100)
    assert n.frozen?
    assert_equal :eq, n.type
    assert_equal 'price', n.left
    assert_equal 100, n.right
    assert_equal [:eq, 'price', 100], send(:equality_key_of, n)
  end

  def test_in_node_values_deep_frozen
    n = SearchEngine::AST.in_('brand_id', [1, 2, 3])
    assert n.values.frozen?
    assert_raises(FrozenError) { n.values << 4 }
  end

  def test_equality_and_hash
    a1 = SearchEngine::AST.and_(
      SearchEngine::AST.eq(:active, true),
      SearchEngine::AST.gt(:price, 100)
    )
    a2 = SearchEngine::AST.and_(
      SearchEngine::AST.eq('active', true),
      SearchEngine::AST.gt(:price, 100)
    )

    assert_equal a1, a2
    assert_equal a1.hash, a2.hash

    set = [a1].to_set
    assert_includes set, a2
  end

  def test_boolean_normalization_and_flattening
    a = SearchEngine::AST.eq(:a, 1)
    b = SearchEngine::AST.eq(:b, 2)
    c = SearchEngine::AST.eq(:c, 3)

    nested = SearchEngine::AST.and_(SearchEngine::AST.and_(a, b), c)
    assert_equal :and, nested.type
    assert_equal 3, nested.children.length
    assert_equal [a, b, c], nested.children
  end

  def test_builder_validations
    assert_raises(ArgumentError) { SearchEngine::AST.eq(nil, 1) }
    assert_raises(ArgumentError) { SearchEngine::AST.in_('brand_id', []) }
    assert_raises(ArgumentError) { SearchEngine::AST.matches(:name, nil) }
    assert_raises(ArgumentError) { SearchEngine::AST.prefix(:name, '') }

    # Raw cannot be blank
    assert_raises(ArgumentError) { SearchEngine::AST.raw('  ') }
  end

  def test_debug_output_shape
    n = SearchEngine::AST.and_(
      SearchEngine::AST.eq(:active, true),
      SearchEngine::AST.in_(:brand_id, [1, 2]),
      SearchEngine::AST.or_(SearchEngine::AST.gt(:price, 100), SearchEngine::AST.lt(:price, 10))
    )

    s = n.to_s
    assert_match(/\Aand\(/, s)
    assert_includes s, 'eq('
    assert_includes s, 'in('
    assert_includes s, 'or('

    i = n.inspect
    assert_match(/#<AST and /, i)
  end

  private

  # Reach into node for its equality payload (testing only)
  def equality_key_of(node)
    node.send(:equality_key)
  end
end
