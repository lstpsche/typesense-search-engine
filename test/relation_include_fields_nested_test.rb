# frozen_string_literal: true

require 'test_helper'

class RelationIncludeFieldsNestedTest < Minitest::Test
  class Book < SearchEngine::Base
    collection 'books_nested_select'
    attribute :id, :integer
    attribute :title, :string
    attribute :author_id, :integer

    join :authors, collection: 'authors', local_key: :author_id, foreign_key: :id
    join :orders,  collection: 'orders',  local_key: :id,        foreign_key: :book_id
  end

  def test_nested_include_fields_compiles
    rel = Book.all.joins(:authors).include_fields(:id, :title, authors: %i[first_name last_name])
    params = rel.to_typesense_params
    assert_equal '$authors(first_name,last_name),id,title', params[:include_fields]
  end

  def test_merge_ordering_and_dedupe
    r_1 = Book.all.joins(:authors).include_fields(:id, authors: %i[first_name])
    r_2 = r_1.include_fields(:title, authors: %i[last_name first_name])

    params = r_2.to_typesense_params
    assert_equal '$authors(first_name,last_name),id,title', params[:include_fields]
  end

  def test_unknown_association_raises
    rel = Book.all
    error = assert_raises(SearchEngine::Errors::UnknownJoin) do
      rel.include_fields(invalid_assoc: [:a])
    end
    assert_match(/Unknown join :invalid_assoc/i, error.message)
    assert_match(/Available:/i, error.message)
  end

  def test_plain_select_compatibility
    rel = Book.all.select(:id, :title)
    params = rel.to_typesense_params
    assert_equal 'id,title', params[:include_fields]
  end

  def test_reselect_replaces_both_base_and_nested
    r_1 = Book.all.joins(:authors).include_fields(:id, authors: [:first_name])
    r_2 = r_1.reselect(:title, authors: [:last_name])

    p_1 = r_1.to_typesense_params
    p_2 = r_2.to_typesense_params

    assert_equal '$authors(first_name),id', p_1[:include_fields]
    assert_equal '$authors(last_name),title', p_2[:include_fields]
  end

  def test_unscope_select_clears_both
    r_1 = Book.all.joins(:authors).include_fields(:id, authors: [:first_name])
    r_2 = r_1.unscope(:select)

    p_1 = r_1.to_typesense_params
    p_2 = r_2.to_typesense_params

    assert p_1.key?(:include_fields)
    refute p_2.key?(:include_fields)
  end

  def test_unknown_join_field_raises
    error = assert_raises(SearchEngine::Errors::UnknownJoinField) do
      Book.all.joins(:authors).select(authors: [:frst_name])
    end
    assert_match(/UnknownJoinField:/i, error.message)
    assert_match(/did you mean/i, error.message)
  end
end
