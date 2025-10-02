# frozen_string_literal: true

require 'test_helper'

class MultiResultTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_mr'
    attribute :id, :integer
    attribute :name, :string
  end

  class Brand < SearchEngine::Base
    collection 'brands_mr'
    attribute :id, :integer
    attribute :name, :string
  end

  def raw_result(found: 0, hits: [], collection: nil)
    item = { 'found' => found, 'out_of' => found, 'hits' => hits }
    item['collection'] = collection if collection
    item
  end

  def test_order_and_labels_preserved
    labels = %i[products brands]
    raws = [raw_result(found: 2), raw_result(found: 1)]
    mr = SearchEngine::MultiResult.new(labels: labels, raw_results: raws, klasses: [Product, Brand])

    assert_equal %i[products brands], mr.labels
    assert_equal 2, mr[:products].found
    assert_equal 1, mr['brands'].found

    map = mr.to_h
    assert_equal %i[products brands], map.keys
    assert_instance_of SearchEngine::Result, map[:products]
  end

  def test_accessors_accept_symbol_and_string_and_missing_returns_nil
    labels = %i[products]
    raws = [raw_result(found: 0)]
    mr = SearchEngine::MultiResult.new(labels: labels, raw_results: raws, klasses: [Product])

    assert mr[:products]
    assert mr['products']
    assert_nil mr[:unknown]
  end

  def test_each_label_returns_enumerator_and_iterates
    labels = %i[products brands]
    raws = [raw_result(found: 0), raw_result(found: 0)]
    mr = SearchEngine::MultiResult.new(labels: labels, raw_results: raws, klasses: [Product, Brand])

    enum = mr.each_label
    assert_kind_of Enumerator, enum
    pairs = enum.map { |(l, r)| [l, r.class.name.to_sym] }
    assert_equal [%i[products SearchEngine::Result], %i[brands SearchEngine::Result]], pairs
  end

  def test_integrity_checks_on_size_mismatch
    labels = %i[products brands]
    raws = [raw_result(found: 0)]
    error = assert_raises(ArgumentError) do
      SearchEngine::MultiResult.new(labels: labels, raw_results: raws, klasses: [Product, Brand])
    end
    assert_match(/does not match/, error.message)
  end

  def test_hydration_falls_back_to_registry_when_no_klass
    labels = %i[products]
    raws = [raw_result(found: 1, hits: [{ 'document' => { 'id' => 1, 'name' => 'A' } }], collection: 'products_mr')]

    mr = SearchEngine::MultiResult.new(labels: labels, raw_results: raws, klasses: nil)

    result = mr[:products]
    refute result.empty?
    obj = result.to_a.first
    # Attributes assigned as instance variables on model instance
    assert_equal 1, obj.instance_variable_get(:@id)
    assert_equal 'A', obj.instance_variable_get(:@name)
  end

  def test_hydration_falls_back_to_openstruct_when_unknown
    labels = %i[unknown]
    raws = [raw_result(found: 1, hits: [{ 'document' => { 'id' => 2, 'x' => 'y' } }], collection: 'not_registered')]

    mr = SearchEngine::MultiResult.new(labels: labels, raw_results: raws, klasses: nil)

    obj = mr[:unknown].to_a.first
    assert_equal 2, obj.id
    assert_equal 'y', obj.x
  end
end
