# frozen_string_literal: true

require 'test_helper'
require 'active_support/notifications'
require 'stringio'
require 'search_engine/notifications/compact_logger'

class MultiInstrumentationTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_multi_instr'
    identify_by :id
    attribute :name, :string
  end

  class Brand < SearchEngine::Base
    collection 'brands_multi_instr'
    identify_by :id
    attribute :name, :string
  end

  def teardown
    SearchEngine::Notifications::CompactLogger.unsubscribe
  rescue StandardError
    nil
  end

  def build_relation(klass)
    klass.all.select(:id, :name).page(1).per(2)
  end

  def test_emits_event_with_labels_and_count
    client = Minitest::Mock.new
    raw = {
      'results' => [
        { 'found' => 0, 'hits' => [] },
        { 'found' => 0, 'hits' => [] }
      ]
    }
    client.expect(:multi_search, raw) do |searches:, url_opts:|
      assert_equal 2, searches.size
      assert url_opts.key?(:use_cache)
    end

    received = []
    sub = ActiveSupport::Notifications.subscribe('search_engine.multi_search') do |*args|
      ev = ActiveSupport::Notifications::Event.new(*args)
      received << ev
    end

    SearchEngine::Client.stub(:new, client) do
      SearchEngine.multi_search(common: {}) do |m|
        m.add :products, build_relation(Product)
        m.add :brands,   build_relation(Brand)
      end
    end

    ActiveSupport::Notifications.unsubscribe(sub)

    assert_equal 1, received.size
    payload = received.first.payload
    assert_equal 2, payload[:searches_count]
    assert_equal %w[products brands], payload[:labels]
    assert_equal 200, payload[:http_status]
    assert received.first.duration.positive?

    # Ensure no sensitive per-search params are included
    refute_includes payload.keys, :params
  end

  def test_event_on_api_error_sets_http_status
    client = Object.new
    def client.multi_search(*_args)
      body = { 'results' => [{ 'status' => 200 }, { 'status' => 404 }] }
      raise SearchEngine::Errors::Api.new('upstream error', status: 404, body: body)
    end

    received = []
    sub = ActiveSupport::Notifications.subscribe('search_engine.multi_search') do |*args|
      ev = ActiveSupport::Notifications::Event.new(*args)
      received << ev
    end

    raised = nil
    SearchEngine::Client.stub(:new, client) do
      raised = assert_raises(SearchEngine::Errors::Api) do
        SearchEngine.multi_search(common: {}) do |m|
          m.add :products, build_relation(Product)
          m.add :brands,   build_relation(Brand)
        end
      end
    end

    ActiveSupport::Notifications.unsubscribe(sub)

    assert_instance_of SearchEngine::Errors::Api, raised
    refute_empty received
    payload = received.first.payload
    assert_equal 404, payload[:http_status]
  end

  def test_compact_logger_line_shape_for_multi
    io = StringIO.new
    logger = Logger.new(io)
    logger.level = Logger::INFO
    SearchEngine::Notifications::CompactLogger.subscribe(logger: logger, level: :info)

    client = Minitest::Mock.new
    raw = { 'results' => [{ 'found' => 0, 'hits' => [] }] }
    client.expect(:multi_search, raw) do |searches:, url_opts:|
      assert_equal 1, searches.size
      assert url_opts.key?(:use_cache)
    end

    SearchEngine::Client.stub(:new, client) do
      SearchEngine.multi_search(common: {}) do |m|
        m.add :products, build_relation(Product)
      end
    end

    logger.close
    line = io.string.lines.find { |l| l.include?('[se.multi]') }
    refute_nil line
    assert_includes line, 'count=1'
    assert_includes line, 'labels=products'
    assert_includes line, 'status=200'
    assert_includes line, 'duration='
  end
end
