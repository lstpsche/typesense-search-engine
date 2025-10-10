# frozen_string_literal: true

require 'test_helper'

class CurationTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_curation'
    identify_by :id
  end

  def test_pin_and_hide_chainers_are_immutable_and_preserve_semantics
    r_1 = Product.all
    r_2 = r_1.pin('p_12', 'p_34').hide('p_99')

    refute_equal r_1.object_id, r_2.object_id

    state = r_2.instance_variable_get(:@state)
    cur = state[:curation]
    assert_equal %w[p_12 p_34], cur[:pinned]
    assert_equal %w[p_99], cur[:hidden]

    r_3 = r_2.pin('p_12') # duplicate, should not re-add
    cur_3 = r_3.instance_variable_get(:@state)[:curation]
    assert_equal %w[p_12 p_34], cur_3[:pinned]

    r_4 = r_3.hide('p_99') # duplicate hidden
    cur_4 = r_4.instance_variable_get(:@state)[:curation]
    assert_equal %w[p_99], cur_4[:hidden]
  end

  def test_curate_replaces_provided_keys_and_clear_works
    r =
      Product
      .all
      .pin('x')
      .curate(pin: %w[a b], hide: %w[x], override_tags: %w[tag1], filter_curated_hits: false)

    cur = r.instance_variable_get(:@state)[:curation]
    assert_equal %w[a b], cur[:pinned]
    assert_equal %w[x], cur[:hidden]
    assert_equal %w[tag1], cur[:override_tags]
    assert_equal false, cur[:filter_curated_hits]

    r_2 = r.clear_curation
    assert_nil r_2.instance_variable_get(:@state)[:curation]
  end

  def test_curate_methods
    rel = Product.all.curate(filter_curated_hits: true)
    params = rel.to_typesense_params
    assert_equal({ filter_curated_hits: true }, params[:_curation])
  end
end
