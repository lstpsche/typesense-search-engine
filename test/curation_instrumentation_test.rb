# frozen_string_literal: true

require 'test_helper'
require 'active_support/notifications'
require 'stringio'
require 'search_engine/notifications/compact_logger'

class CurationInstrumentationTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_curation_instr'
    attribute :id, :string
  end

  def teardown
    SearchEngine::Notifications::CompactLogger.unsubscribe
  rescue StandardError
    nil
  end

  def test_curation_compile_event_emitted_with_counts
    skip 'ActiveSupport::Notifications not available' unless defined?(ActiveSupport::Notifications)

    received = []
    sub = ActiveSupport::Notifications.subscribe('search_engine.curation.compile') do |*args|
      ev = ActiveSupport::Notifications::Event.new(*args)
      received << ev
    end

    begin
      rel = Product.all.curate(pin: %w[p1 p2], hide: %w[h1], override_tags: %w[tag], filter_curated_hits: false)
      compiled = rel.to_typesense_params
      refute_nil compiled
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    assert_equal 1, received.length
    payload = received.first.payload
    assert_equal 2, payload[:pinned_count]
    assert_equal 1, payload[:hidden_count]
    assert_equal true, payload[:has_override_tags]
    assert_equal false, payload[:filter_curated_hits]
  end

  def test_curation_conflict_overlap_emitted_once
    skip 'ActiveSupport::Notifications not available' unless defined?(ActiveSupport::Notifications)

    received = []
    sub = ActiveSupport::Notifications.subscribe('search_engine.curation.conflict') do |*args|
      ev = ActiveSupport::Notifications::Event.new(*args)
      received << ev
    end

    begin
      # overlap: same id in pin and hide
      rel = Product.all.curate(pin: %w[x1 x2], hide: %w[x1])
      compiled = rel.to_typesense_params
      refute_nil compiled
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    assert_equal 1, received.length
    payload = received.first.payload
    assert_equal :overlap, payload[:type]
    assert_equal 1, payload[:count]
    refute_includes payload.keys, :limit
  end

  def test_compact_logger_includes_curation_segment_in_text
    io = StringIO.new
    logger = Logger.new(io)
    logger.level = Logger::INFO
    SearchEngine::Notifications::CompactLogger.subscribe(logger: logger, level: :info)

    # Fake Typesense client to satisfy Client#search
    ts = Class.new do
      def collections
        self
      end

      def [](_name)
        self
      end

      def documents
        self
      end

      def search(*_)
        { 'found' => 0, 'hits' => [] }
      end
    end.new

    client = SearchEngine::Client.new(typesense_client: ts)
    params = { q: '*', query_by: 'name', pinned_hits: 'p1,p2' }
    client.search(collection: 'products_curation_instr', params: params, url_opts: {})

    logger.close
    line = io.string.lines.find { |l| l.include?('[se.search]') }
    refute_nil line
    assert_includes line, 'cu=p:2|h:0'
  end
end
