# frozen_string_literal: true

# Minimal repro for R-001 (friendly NOT IN mapping)
# These specs are discovery-only and not wired to CI.

require 'minitest/autorun'
require_relative '../../lib/search_engine'

class R001NotInFriendlyWhereSpec < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_r001'
    attribute :id, :integer
  end

  def test_explain_displays_not_in
    pending 'fix in M11'
    rel = Product.all.where('brand_id:!=[1,2]')
    assert_includes rel.explain, 'NOT IN'
  end
end
