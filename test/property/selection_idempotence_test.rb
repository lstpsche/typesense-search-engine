# frozen_string_literal: true

require 'test_helper'

# Optional property check: selection chaining idempotence
class PropertySelectionIdempotenceTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_property_selection'
    attribute :id, :integer
    attribute :name, :string
  end

  def test_select_idempotence
    skip

    r1 = Product.all.select(:id).select(:id)
    r2 = Product.all.select(:id)
    assert_equal r2.to_typesense_params[:include_fields], r1.to_typesense_params[:include_fields]
  end
end
