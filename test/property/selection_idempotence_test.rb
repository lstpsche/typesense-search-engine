# frozen_string_literal: true

require 'test_helper'

# Optional property check: selection chaining idempotence
class PropertySelectionIdempotenceTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_property_selection'
    identify_by :id
    attribute :name, :string
  end

  def test_multiple_selections_idempotent
    r = Product.all.select(:id, :name).select(:name)
    params = r.to_typesense_params
    assert_equal 'id,name', params[:include_fields]
  end
end
