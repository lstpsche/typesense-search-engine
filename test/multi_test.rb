# frozen_string_literal: true

require 'test_helper'
require 'search_engine/multi'
require 'search_engine/client'

class MultiTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_multi'
    attribute :id, :integer
    attribute :name, :string
  end

  class Brand < SearchEngine::Base
    collection 'brands_multi'
    attribute :id, :integer
    attribute :name, :string
  end

  def build_relation(klass)
    klass.all.select(:id, :name).page(1).per(2)
  end

  def test_add_and_labels_preserve_order
    m = SearchEngine::Multi.new
    m.add(:products, build_relation(Product))
    m.add('brands', build_relation(Brand))
    assert_equal %i[products brands], m.labels
  end

  def test_duplicate_label_raises
    m = SearchEngine::Multi.new
    m.add(:products, build_relation(Product))
    error = assert_raises(ArgumentError) { m.add('Products', build_relation(Product)) }
    assert_match(/duplicate label/i, error.message)
  end

  def test_to_payloads_common_merge_and_shape
    m = SearchEngine::Multi.new
    rel = Product.all.select(:id).per(1)
    m.add(:products, rel)

    payloads = m.to_payloads(common: { q: 'x', query_by: 'name', per_page: 99 })
    assert_equal 1, payloads.size
    p = payloads.first
    assert_equal 'products_multi', p[:collection]
    # per-search wins over common; Relation defaults q: "*"
    assert_equal '*', p[:q]
    # per-search keys win over common: Relation set per_page: 1 should override 99
    assert_equal 1, p[:per_page]
    assert_equal 'name', p[:query_by]
  end

  def test_api_key_unsupported_raises
    m = SearchEngine::Multi.new
    rel = build_relation(Product)
    error = assert_raises(ArgumentError) { m.add(:products, rel, api_key: 'secret') }
    assert_match(/not supported/i, error.message)
  end

  def test_module_helper_executes_and_maps_results
    # Stub client.multi_search to return two empty results with counts
    client = Minitest::Mock.new
    raw = {
      'results' => [
        { 'found' => 2, 'out_of' => 2, 'hits' => [] },
        { 'found' => 1, 'out_of' => 1, 'hits' => [] }
      ]
    }
    client.expect(:multi_search, raw) do |searches:, url_opts:|
      assert_equal 2, searches.size
      assert_equal true, url_opts.key?(:use_cache)
      true
    end

    # Monkey-patch a temporary client instance into the helper path by stubbing .new
    SearchEngine::Client.stub(:new, client) do
      result_set = SearchEngine.multi_search(common: { query_by: 'name' }) do |m|
        m.add :products, build_relation(Product)
        m.add :brands,   build_relation(Brand)
      end

      assert_equal %i[products brands], result_set.labels
      assert_equal 2, result_set[:products].found
      assert_equal 1, result_set['brands'].found
      map = result_set.to_h
      assert_equal 2, map.size
      assert map.key?(:products)
    end

    client.verify
  end
end
