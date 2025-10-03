# frozen_string_literal: true

require 'test_helper'

class RelationFieldSelectionTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_field_selection'
    attribute :id, :integer
    attribute :name, :string
    attribute :active, :boolean
  end

  def test_exclude_only_emits_exclude_fields
    rel = Product.all.exclude(:name)
    params = rel.to_typesense_params

    refute params.key?(:include_fields)
    assert_equal 'name', params[:exclude_fields]
  end

  def test_include_minus_exclude
    rel = Product.all.select(:id, :name).exclude(:name)
    params = rel.to_typesense_params

    assert_equal 'id', params[:include_fields]
    refute params.key?(:exclude_fields)
  end

  def test_reselect_clears_excludes
    r1 = Product.all.select(:id).exclude(:name)
    r2 = r1.reselect(:name)

    p2 = r2.to_typesense_params
    assert_equal 'name', p2[:include_fields]
    refute p2.key?(:exclude_fields)
  end
end
