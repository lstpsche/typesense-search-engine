# frozen_string_literal: true

require 'test_helper'
require 'search_engine/multi'

class MultiPresetsTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_multi_presets'
    attribute :id, :integer
    attribute :active, :bool
    attribute :updated_at, :integer
  end

  class Brand < SearchEngine::Base
    collection 'brands_multi_presets'
    attribute :id, :integer
    attribute :name, :string
  end

  def setup
    @orig_ns = SearchEngine.config.presets.namespace
    @orig_enabled = SearchEngine.config.presets.enabled
    @orig_locked = SearchEngine.config.presets.locked_domains
    SearchEngine.config.presets.enabled = true
    SearchEngine.config.presets.namespace = 'prod'
    SearchEngine.config.presets.locked_domains = %i[filter_by sort_by include_fields exclude_fields]
  end

  def teardown
    SearchEngine.config.presets.namespace = @orig_ns
    SearchEngine.config.presets.enabled = @orig_enabled
    SearchEngine.config.presets.locked_domains = @orig_locked
  end

  def test_merge_and_only_modes_shape_payloads
    rel_merge = Product.all.preset(:popular_products, mode: :merge).per(5)
    rel_only  = Brand.all.preset(:brand_popularity, mode: :only).per(3)

    m = SearchEngine::Multi.new
    m.add :products, rel_merge
    m.add :brands,   rel_only

    payloads = m.to_payloads(common: { query_by: 'name', filter_by: 'x:=1' })

    p_merge = payloads[0]
    assert_equal 'products_multi_presets', p_merge[:collection]
    assert_equal 'prod_popular_products', p_merge[:preset]
    assert_equal '*', p_merge[:q]
    assert_equal 5, p_merge[:per_page]

    p_only = payloads[1]
    assert_equal 'brands_multi_presets', p_only[:collection]
    assert_equal 'prod_brand_popularity', p_only[:preset]
    assert_equal '*', p_only[:q]
    assert_equal 3, p_only[:per_page]
    refute_includes p_only.keys, :filter_by
    refute_includes p_only.keys, :sort_by
    refute_includes p_only.keys, :query_by
  end

  def test_lock_mode_drops_locked_domains_even_if_common_provides_them
    SearchEngine.config.presets.locked_domains = %i[filter_by sort_by]

    rel = Product.all.preset(:curated, mode: :lock)
    m = SearchEngine::Multi.new
    m.add :products, rel

    payloads = m.to_payloads(common: { filter_by: 'active:=true', sort_by: 'name:asc' })
    p = payloads.first

    assert_equal 'prod_curated', p[:preset]
    refute_includes p.keys, :filter_by
    refute_includes p.keys, :sort_by
  end

  def test_only_mode_retains_essentials_only
    rel = Brand.all.preset(:brand_popularity, mode: :only).per(2)

    m = SearchEngine::Multi.new
    m.add :brands, rel

    p = m.to_payloads(common: { query_by: 'name' }).first

    %i[collection q per_page preset].each { |k| assert_includes p.keys, k }
    extras = p.keys - %i[collection q page per_page preset]
    assert_equal [], extras
  end
end
