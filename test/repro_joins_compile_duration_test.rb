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
    skip 'ActiveSupport::Notifications not available' unless defined?(ActiveSupport::Notifications)

    received = []
    sub = ActiveSupport::Notifications.subscribe('search_engine.joins.compile') do |*args|
      ev = ActiveSupport::Notifications::Event.new(*args)
      received << ev
    end

    begin
      rel = Book.all.joins(:authors)
      params = SearchEngine::CompiledParams.from(rel.to_typesense_params)
      refute_nil params
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    assert_equal 1, received.length
    payload = received.first.payload
    assert payload.key?(:duration_ms), 'expected duration_ms in joins.compile payload'
    assert_kind_of Numeric, payload[:duration_ms]
  end
end
