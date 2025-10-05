# frozen_string_literal: true

require 'test_helper'

# See tmp/refactor/logic_review.md, row ID R-001
class ReproNotInFriendlyWhereTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_repro_not_in'
    attribute :id, :integer
  end

  def test_explain_maps_not_in_token
    rel = Product.all.where('brand_id:!=[1,2]')
    exp = rel.explain
    assert_includes exp, 'NOT IN'
  end
end
