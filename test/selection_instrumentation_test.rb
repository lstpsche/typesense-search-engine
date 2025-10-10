# frozen_string_literal: true

require 'test_helper'
require 'active_support/notifications'

class SelectionInstrumentationTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_selection_instr'
    identify_by :id
    attribute :author_id, :integer
    join :authors, collection: 'authors', local_key: :author_id, foreign_key: :id
  end

  def test_selection_compile_event_emitted_with_counts
    skip 'ActiveSupport::Notifications not available' unless defined?(ActiveSupport::Notifications)

    received = []
    sub = ActiveSupport::Notifications.subscribe('search_engine.selection.compile') do |*args|
      ev = ActiveSupport::Notifications::Event.new(*args)
      received << ev
    end

    begin
      rel = Product.all
                   .joins(:authors)
                   .select(:id, authors: [:id])
                   .exclude(:author_id, authors: [:id])
      compiled = rel.to_typesense_params
      refute_nil compiled
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    assert_equal 1, received.length
    payload = received.first.payload
    assert_kind_of Integer, payload[:include_count]
    assert_kind_of Integer, payload[:exclude_count]
    assert_kind_of Integer, payload[:nested_assoc_count]
  end
end
