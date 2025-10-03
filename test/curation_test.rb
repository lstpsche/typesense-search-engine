# frozen_string_literal: true

require 'test_helper'

class CurationTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_curation'
    attribute :id, :string
  end

  def test_pin_and_hide_chainers_are_immutable_and_preserve_semantics
    r1 = Product.all
    r2 = r1.pin('p_12', 'p_34').hide('p_99')

    refute_equal r1.object_id, r2.object_id

    state = r2.instance_variable_get(:@state)
    cur = state[:curation]
    assert_equal %w[p_12 p_34], cur[:pinned]
    assert_equal %w[p_99], cur[:hidden]

    r3 = r2.pin('p_12') # duplicate, should not re-add
    cur3 = r3.instance_variable_get(:@state)[:curation]
    assert_equal %w[p_12 p_34], cur3[:pinned]

    r4 = r3.hide('p_99') # duplicate hidden
    cur4 = r4.instance_variable_get(:@state)[:curation]
    assert_equal %w[p_99], cur4[:hidden]
  end

  def test_curate_replaces_provided_keys_and_clear_works
    r =
      Product
      .pin('x')
      .curate(pin: %w[a b], hide: %w[x], override_tags: %w[tag1], filter_curated_hits: false)

    cur = r.instance_variable_get(:@state)[:curation]
    assert_equal %w[a b], cur[:pinned]
    assert_equal %w[x], cur[:hidden]
    assert_equal %w[tag1], cur[:override_tags]
    assert_equal false, cur[:filter_curated_hits]

    r2 = r.clear_curation
    assert_nil r2.instance_variable_get(:@state)[:curation]
  end
end
