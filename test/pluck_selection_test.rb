# frozen_string_literal: true

require 'test_helper'

class PluckSelectionTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_pluck_sel'
    identify_by :id
    attribute :name, :string
    attribute :price, :float
  end

  def stub_client_raising_if_called
    Class.new do
      def search(*_)
        raise 'network should not be called for invalid pluck'
      end
    end.new
  end

  def build_result(hits: [])
    raw = { 'found' => hits.size, 'out_of' => hits.size, 'hits' => hits.map { |doc| { 'document' => doc } } }
    SearchEngine::Result.new(raw, klass: Product)
  end

  def test_example_missing_field_suggests_reselect
    rel = Product.all.select(:id)
    # Ensure no network is attempted when invalid
    rel.instance_variable_set(:@__client, stub_client_raising_if_called)

    error = assert_raises(SearchEngine::Errors::InvalidSelection) do
      # Example:
      #
      # SearchEngine::Product.select(:id).pluck(:name)
      # raises InvalidSelection: field :name not in effective selection. Use `reselect(:id,:name)`.
      rel.pluck(:name)
    end
    assert_match(/InvalidSelection: field :name not in effective selection\./, error.message)
    assert_match(/Use `reselect\(:id,:name\)`\./, error.message)
  end

  def test_exclude_wins_suggest_remove_exclude
    rel = Product.all.select(:id, :name).exclude(:name)
    rel.instance_variable_set(:@__client, stub_client_raising_if_called)

    error = assert_raises(SearchEngine::Errors::InvalidSelection) { rel.pluck(:name) }
    assert_match(/Remove exclude\(:name\)/, error.message)
  end

  def test_pluck_success_when_selected
    rel = Product.all.reselect(:id, :name)
    result = build_result(hits: [{ 'id' => 1, 'name' => 'A' }, { 'id' => 2, 'name' => 'B' }])
    rel.instance_variable_set(:@__result_memo, result)
    rel.instance_variable_set(:@__loaded, true)

    assert_equal %w[A B], rel.pluck(:name)
  end

  def test_pluck_multiple_fields_order_preserved
    rel = Product.all.reselect(:id, :name, :price)
    result = build_result(
      hits: [
        { 'id' => 1, 'name' => 'A', 'price' => 9.99 },
        { 'id' => 2, 'name' => 'B', 'price' => 19.5 }
      ]
    )
    rel.instance_variable_set(:@__result_memo, result)
    rel.instance_variable_set(:@__loaded, true)

    rows = rel.pluck(:id, :name, :price)
    assert_equal [[1, 'A', 9.99], [2, 'B', 19.5]], rows
  end

  def test_ids_requires_id_not_excluded
    rel = Product.all.exclude(:id)
    rel.instance_variable_set(:@__client, stub_client_raising_if_called)

    error = assert_raises(SearchEngine::Errors::InvalidSelection) { rel.ids }
    assert_match(/Remove exclude\(:id\)/, error.message)
  end

  def test_ids_works_when_permitted
    rel = Product.all # include empty -> all permitted unless explicitly excluded
    result = build_result(hits: [{ 'id' => 1 }, { 'id' => 2 }])
    rel.instance_variable_set(:@__result_memo, result)
    rel.instance_variable_set(:@__loaded, true)

    assert_equal [1, 2], rel.ids
  end
end
