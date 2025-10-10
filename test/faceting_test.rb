# frozen_string_literal: true

require 'test_helper'

class FacetingTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_facet'
    identify_by :id
    attribute :brand_id, :integer
    attribute :category, :string
    attribute :price, :float
  end

  def test_facet_by_and_query_compile
    r = Product.all
               .facet_by(:brand_id, max_values: 5)
               .facet_by('category')
               .facet_query(:price, '[0..9]', label: 'under_10')

    params = r.to_typesense_params
    assert_equal 'brand_id,category', params[:facet_by]
    assert_equal 5, params[:max_facet_values]
    assert_equal 'price:[0..9]', params[:facet_query]
  end

  def test_result_facets_helpers
    raw = {
      'found' => 1,
      'out_of' => 1,
      'facet_counts' => [
        { 'field_name' => 'brand_id', 'counts' => [{ 'value' => '123', 'count' => 10 }] },
        { 'field_name' => 'price', 'counts' => [{ 'value' => '[0..9]', 'count' => 4 }] }
      ],
      'hits' => []
    }

    facets_ctx = { fields: %w[brand_id price], queries: [{ field: 'price', expr: '[0..9]', label: 'under_10' }] }
    res = SearchEngine::Result.new(raw, klass: Product, facets: facets_ctx)

    map = res.facet_value_map('brand_id')
    assert_equal 10, map['123']

    vals = res.facet_values('price')
    assert_equal 'under_10', vals.first[:label]
  end
end
