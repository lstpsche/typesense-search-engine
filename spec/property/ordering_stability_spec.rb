# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/search_engine'

class OrderingStabilitySpec < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_prop_ordering'
  end

  def test_compiled_key_order_stable
    rel = Product.all.where(active: true).order(updated_at: :desc).page(2).per(10)
    p1 = SearchEngine::CompiledParams.from(rel.to_typesense_params).to_h.keys
    p2 = SearchEngine::CompiledParams.from(rel.to_typesense_params).to_h.keys
    assert_equal p1, p2
  end
end
