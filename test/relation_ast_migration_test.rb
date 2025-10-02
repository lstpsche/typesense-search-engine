# frozen_string_literal: true

require 'test_helper'

class RelationASTMigrationTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_relation_migration'
    attribute :id, :integer
    attribute :active, :boolean
    attribute :price, :float
    attribute :brand_id, :integer
  end

  def test_legacy_filters_migrate_to_ast_raw
    r = SearchEngine::Relation.new(Product, { filters: ['active:=true', 'brand_id:=[1,2]'] })

    assert_equal 2, r.ast.length
    filter_by = r.to_typesense_params[:filter_by]
    assert_match(/active:=true/, filter_by)
    assert_match(/brand_id:=\[1,\s*2\]/, filter_by)
  end

  def test_compilation_prefers_ast
    r = Product.all.where(id: 1).where(['price > ?', 100])
    compiled = SearchEngine::Compiler.compile(r.ast, klass: Product)
    assert_equal compiled, r.to_typesense_params[:filter_by]
  end
end
