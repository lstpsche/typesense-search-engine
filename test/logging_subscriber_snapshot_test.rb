# frozen_string_literal: true

require 'test_helper'
require 'logger'
require 'search_engine/logging_subscriber'

class LoggingSubscriberSnapshotTest < Minitest::Test
  EventStub = Struct.new(:name, :payload, :duration)

  def with_correlation(id, &block)
    SearchEngine::Instrumentation.with_correlation_id(id, &block)
  end

  def format_line(event)
    SearchEngine::LoggingSubscriber.send(:format_compact, event)
  end

  def test_generic_search_like_event_compact_line
    p = {
      collection: 'products',
      status: :ok,
      groups_count: 3,
      preset_name: 'promo',
      curation_pinned_count: 1,
      curation_hidden_count: 0,
      correlation_id: 'abcd1234'
    }
    ev = EventStub.new('search_engine.search', p, 7.8)

    line = format_line(ev)
    # short cid should truncate to first 4 chars
    assert_equal '[se.search] id=abcd coll=products status=ok dur=7.8ms groups=3 preset=promo cur=1/0', line
  end

  def test_hits_limit_specialized_renderer
    p = {
      collection: 'products',
      early_limit: 200,
      validate_max: 1000,
      applied_strategy: 'cap_total',
      triggered: true,
      total_hits: 1200,
      correlation_id: 'ff001122'
    }
    ev = EventStub.new('search_engine.hits.limit', p, 0.5)

    line = format_line(ev)
    expected = +'[se.hits.limit] id=ff00 coll=products early=200 max=1000 '
    expected << 'strat=cap_total trig=true total=1200 status=ok dur=0.5ms'
    assert_equal expected, line
  end
end
