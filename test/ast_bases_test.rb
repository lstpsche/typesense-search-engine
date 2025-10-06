# frozen_string_literal: true

require 'minitest/autorun'
require 'search_engine/ast'

class ASTBasesTest < Minitest::Test
  class DummyBinary < SearchEngine::AST::BinaryOp
    def type = :dummy_binary
  end

  class DummyUnary < SearchEngine::AST::UnaryOp
    def type = :dummy_unary
  end

  def test_binary_op_freeze_and_children
    node = DummyBinary.new(:price, [1, 2])
    assert node.frozen?
    assert_equal 'price', node.left
    assert_equal [1, 2], node.right
    assert node.right.frozen?
    assert_equal [:dummy_binary, 'price', [1, 2]], equality_key_of(node)
    assert_equal ['price', [1, 2]], node.children

    i = node.inspect
    assert_includes i, 'field=price'
    assert_includes i, 'value=[1, 2]'
  end

  def test_unary_op_child_validation_message
    error = assert_raises(ArgumentError) { DummyUnary.new(Object.new) }
    assert_equal 'child must be a SearchEngine::AST::Node', error.message
  end

  def test_membership_inspect_key_and_values
    node = SearchEngine::AST.in_('brand_id', [1, 2])
    assert_equal [1, 2], node.values
    assert_includes node.inspect, 'values=[1, 2]'
  end

  def test_comparison_readers_and_to_s
    node = SearchEngine::AST.eq(:price, 100)
    assert_equal :eq, node.type
    assert_equal 'price', node.left
    assert_equal 100, node.value
    assert_match(/\Aeq\(/, node.to_s)
  end

  private

  def equality_key_of(node)
    node.send(:equality_key)
  end
end
