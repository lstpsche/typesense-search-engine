# frozen_string_literal: true

require 'test_helper'

class RelationRechainersTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_rechainers'
    attribute :id, :integer
    attribute :name, :string
    attribute :active, :boolean
    attribute :price, :float
    attribute :brand_id, :integer
  end

  def test_reselect_replaces_and_normalizes
    r1 = Product.all.select(:id, :name)
    r2 = r1.reselect(' name ', :id, :name, :id)

    # Immutability
    refute_equal r1.object_id, r2.object_id

    # Replaced selection (first occurrence preserved, deduped)
    params1 = r1.to_typesense_params
    params2 = r2.to_typesense_params
    assert_equal 'id,name', params1[:include_fields]
    assert_equal 'name,id', params2[:include_fields]
  end

  def test_reselect_empty_raises
    r = Product.all.select(:id)
    assert_raises(ArgumentError) { r.reselect }
  end

  def test_rewhere_clears_previous_predicates_and_sets_new_ast
    r1 = Product.all.where(id: 1).where(['price > ?', 100])
    r2 = r1.rewhere(active: true)

    # Immutability
    refute_equal r1.object_id, r2.object_id

    # Previous AST cleared, new AST present
    assert_equal 1, r2.ast.length
    compiled = r2.to_typesense_params[:filter_by]
    assert_equal 'active:=true', compiled

    # Legacy filters cleared as well
    state = r2.instance_variable_get(:@state)
    assert_equal [], Array(state[:filters])
  end

  def test_rewhere_blank_raises
    r = Product.all.where(id: 1)
    assert_raises(ArgumentError) { r.rewhere(nil) }
    assert_raises(ArgumentError) { r.rewhere('') }
    assert_raises(ArgumentError) { r.rewhere([]) }
    assert_raises(ArgumentError) { r.rewhere({}) }
  end

  def test_unscope_where_clears_predicates
    r1 = Product.all.where(id: 1).where(['price > ?', 100])
    r2 = r1.unscope(:where)

    refute_equal r1.object_id, r2.object_id

    params = r2.to_typesense_params
    refute params.key?(:filter_by)

    state = r2.instance_variable_get(:@state)
    assert_equal [], Array(state[:ast])
    assert_equal [], Array(state[:filters])
  end

  def test_unscope_order_select_and_pagination
    r1 = Product.all.order(name: :asc).select(:id, :name).page(2).per(10).limit(5).offset(5)
    r2 = r1.unscope(:order, :select, :limit, :offset)

    p1 = r1.to_typesense_params
    p2 = r2.to_typesense_params

    # order cleared
    assert p1.key?(:sort_by)
    refute p2.key?(:sort_by)

    # select cleared
    assert p1.key?(:include_fields)
    refute p2.key?(:include_fields)

    # limit/offset cleared; page/per still present
    assert_equal 2, p2[:page]
    assert_equal 10, p2[:per_page]
  end

  def test_unscope_page_and_per
    r1 = Product.all.page(3).per(15)
    r2 = r1.unscope(:page, :per)

    p = r2.to_typesense_params
    refute p.key?(:page)
    refute p.key?(:per_page)
  end

  def test_unscope_unknown_raises
    r = Product.all
    error = assert_raises(ArgumentError) { r.unscope(:foo) }
    assert_match(/unscope: unknown part/i, error.message)
  end

  def test_composition_reselect_unscope_rewhere
    r = Product.all.select(:id).order(name: :asc)
    r = r.reselect(:name).unscope(:order).rewhere(['price > ?', 50])

    params = r.to_typesense_params
    assert_equal 'name', params[:include_fields]
    refute params.key?(:sort_by)
    assert_equal 'price:>50', params[:filter_by]
  end
end
