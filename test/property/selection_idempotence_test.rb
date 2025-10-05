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

    r_1 = Product.all.select(:id).select(:id)
    r_2 = Product.all.select(:id)
    assert_equal r_2.to_typesense_params[:include_fields], r_1.to_typesense_params[:include_fields]
  end
end
