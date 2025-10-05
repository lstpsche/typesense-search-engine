# frozen_string_literal: true

require 'test_helper'

class RelationFieldSelectionTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_field_selection'
    attribute :id, :integer
    attribute :name, :string
    attribute :active, :boolean
  end

  module ::SearchEngine
    class Book < SearchEngine::Base
      collection 'books_field_selection'
      attribute :id, :integer
      attribute :title, :string
      attribute :author_id, :integer
      attribute :brand_id, :integer
      attribute :legacy, :string

      join :authors, collection: 'authors', local_key: :author_id, foreign_key: :id
      join :brands,  collection: 'brands',  local_key: :brand_id,  foreign_key: :id
    end
  end

  def test_exclude_only_emits_exclude_fields
    rel = Product.all.exclude(:name)
    params = rel.to_typesense_params

    refute params.key?(:include_fields)
    assert_equal 'name', params[:exclude_fields]
  end

  def test_include_minus_exclude
    rel = Product.all.select(:id, :name).exclude(:name)
    params = rel.to_typesense_params

    assert_equal 'id', params[:include_fields]
    refute params.key?(:exclude_fields)
  end

  def test_reselect_clears_excludes
    r_1 = Product.all.select(:id).exclude(:name)
    r_2 = r_1.reselect(:name)

    p_2 = r_2.to_typesense_params
    assert_equal 'name', p_2[:include_fields]
    refute p_2.key?(:exclude_fields)
  end

  def test_nested_exclude_only_emits_nested_exclude_fields
    rel = RelationIncludeFieldsNestedTest::Book.all.joins(:authors).exclude(authors: %i[last_name first_name])
    params = rel.to_typesense_params

    refute params.key?(:include_fields)
    assert_equal '$authors(first_name,last_name)', params[:exclude_fields]
  end

  def test_nested_include_and_exclude_precedence
    rel = RelationIncludeFieldsNestedTest::Book
          .all
          .joins(:authors)
          .select(:id, authors: %i[first_name last_name])
          .exclude(authors: [:last_name])
    params = rel.to_typesense_params

    assert_equal '$authors(first_name),id', params[:include_fields]
    refute params.key?(:exclude_fields)
  end

  def test_example
    rel = SearchEngine::Book
          .all
          .joins(:authors, :brands)
          .select(:id, :title, authors: %i[first_name last_name])
          .exclude(:legacy, brands: [:internal_score])
    params = rel.to_typesense_params

    assert_equal '$authors(first_name,last_name),id,title', params[:include_fields]
    assert_equal '$brands(internal_score)', params[:exclude_fields]
  end

  def test_unknown_base_field_raises_with_suggestion
    rel = Product.all
    error = assert_raises(SearchEngine::Errors::UnknownField) do
      rel.select(:id, :naem)
    end
    assert_match(/UnknownField/i, error.message)
    assert_match(/did you mean/i, error.message)
  end

  def test_unknown_join_field_raises_with_example_and_suggestion
    error = assert_raises(SearchEngine::Errors::UnknownJoinField) do
      SearchEngine::Book.all.joins(:authors).select(authors: [:middle_name])
    end
    prefix = 'UnknownJoinField: :middle_name is not declared on association :authors for SearchEngine::Book'
    assert_equal prefix, error.message.split(' (did you mean').first
  end

  def test_conflicting_selection_invalid_shape_raises
    rel = Product.all
    error = assert_raises(SearchEngine::Errors::ConflictingSelection) do
      rel.select(123)
    end
    assert_match(/ConflictingSelection/i, error.message)
  end

  def test_exclude_path_validates_unknown_field
    rel = Product.all
    error = assert_raises(SearchEngine::Errors::UnknownField) do
      rel.exclude(:naem)
    end
    assert_match(/UnknownField/i, error.message)
  end

  def test_explain_includes_effective_selection_tokens
    rel = Product
          .all
          .select(:id, :name)
          .exclude(:name)
    summary = rel.explain
    assert_includes summary, 'selection: '
    assert_includes summary, 'sel=id'
    assert_includes summary, 'xsel=name'
  end
end
