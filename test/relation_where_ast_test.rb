# frozen_string_literal: true

require 'test_helper'

class RelationWhereASTTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_relation'
    attribute :id, :integer
    attribute :active, :boolean
    attribute :price, :float
    attribute :brand_id, :integer
  end

  def test_where_populates_filters_ast_and_strings
    r1 = Product.all
    r2 = r1.where({ id: 1 }, ['price > ?', 100], 'brand_id:=[1,2]')

    # Immutability
    refute_equal r1.object_id, r2.object_id

    # String fragments preserved for back-compat
    params = r2.to_typesense_params
    assert_match(/id:=/, params[:filter_by])
    # When using template with placeholders, current sanitizer keeps operator tokens
    assert_match(/price > \d+/, params[:filter_by])

    # AST side-channel present in internal state
    state = r2.instance_variable_get(:@state)
    ast = Array(state[:filters_ast])
    assert_equal 3, ast.length

    # No-op chain preserves AST state
    r3 = r2.where
    state3 = r3.instance_variable_get(:@state)
    assert_equal ast, state3[:filters_ast]
  end
end
