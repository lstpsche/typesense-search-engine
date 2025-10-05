# frozen_string_literal: true

require 'test_helper'

# See tmp/refactor/logic_review.md, row ID R-005
class ReproJoinsCompileDurationTest < Minitest::Test
  class Book < SearchEngine::Base
    collection 'books_repro_joins'
    attribute :id, :integer
    attribute :author_id, :integer
    # Minimal join registry to allow .joins(:authors)
    join :authors, collection: 'authors', local_key: :author_id, foreign_key: :id
  end

  def test_joins_compile_duration_reference
    skip

    rel = Book.all.joins(:authors)
    # This compile path references compile_started_ms without defining it
    # Expect no NameError after fix
    params = rel.to_typesense_params
    refute_nil params
  end
end
