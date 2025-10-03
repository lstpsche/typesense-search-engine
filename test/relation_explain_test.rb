# frozen_string_literal: true

require 'test_helper'

class RelationExplainTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_relation_explain'
    attribute :id, :integer
    attribute :name, :string
    attribute :active, :boolean
    attribute :brand_id, :integer
  end

  def test_explain_returns_friendly_summary
    rel = Product
          .all
          .where(active: true)
          .where(brand_id: [1, 2])
          .order(updated_at: :desc)
          .select(:id, :name)
          .page(2)
          .per(20)

    summary = rel.explain

    assert_includes summary, 'Product Relation'
    assert_includes summary, 'where: '
    assert_includes summary, 'active:=true'
    assert_includes summary, 'AND'
    assert_includes summary, 'brand_id IN [1, 2]'
    assert_includes summary, 'order: updated_at:desc'
    assert_includes summary, 'select: id,name'
    assert_includes summary, 'page/per: 2/20'
    # Effective selection tokens
    assert_includes summary, 'selection: '
    assert_includes summary, 'sel=id,name'
  end

  def test_explain_does_not_hit_network
    stub_client = Class.new do
      def search(*_args)
        raise 'network should not be called by explain'
      end
    end.new

    rel = Product.all.where(active: true)
    rel.instance_variable_set(:@__client, stub_client)

    summary = rel.explain
    refute_nil summary
  end
end
