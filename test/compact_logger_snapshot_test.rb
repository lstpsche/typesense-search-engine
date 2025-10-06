# frozen_string_literal: true

require 'test_helper'
require 'logger'

class CompactLoggerSnapshotTest < Minitest::Test
  EventStub = Struct.new(:payload, :duration)

  def build_logger(io)
    logger = Logger.new(io)
    logger.level = Logger::INFO
    logger.formatter = proc { |_sev, _time, _prog, msg| "#{msg}\n" }
    logger
  end

  def test_search_success_exact_line
    io = StringIO.new
    logger = build_logger(io)

    payload = {
      collection: 'products',
      http_status: 200,
      selection_include_count: 1,
      selection_exclude_count: 0,
      selection_nested_assoc_count: 2,
      preset_name: 'sale',
      curation_pinned_count: 2,
      curation_hidden_count: 0,
      curation_filter_flag: nil,
      curation_has_override_tags: false,
      url_opts: { use_cache: false, cache_ttl: 30 }
    }
    event = EventStub.new(payload, 12.3)

    SearchEngine::Notifications::CompactLogger.emit_line(
      logger, Logger::INFO, event, include_params: false, multi: false
    )

    expected = '[se.search] collection=products status=200 duration=12.3ms cache=false ttl=30 '
    expected << 'sel=I:1|X:0|N:2 pz=sale|ld=4 cu=p:2|h:0|f:∅|t:0'
    assert_equal "#{expected}\n", io.string
  end

  def test_search_error_exact_line
    io = StringIO.new
    logger = build_logger(io)

    payload = {
      collection: 'products',
      http_status: 500,
      selection_include_count: 0,
      selection_exclude_count: 0,
      selection_nested_assoc_count: 0,
      curation_pinned_count: 0,
      curation_hidden_count: 0,
      url_opts: { use_cache: true, cache_ttl: 120 }
    }
    event = EventStub.new(payload, 1.0)

    SearchEngine::Notifications::CompactLogger.emit_line(
      logger, Logger::INFO, event, include_params: false, multi: false
    )

    expected = '[se.search] collection=products status=500 duration=1.0ms cache=true ttl=120 '
    expected << 'sel=I:0|X:0|N:0 cu=p:0|h:0|t:0'
    assert_equal "#{expected}\n", io.string
  end

  def test_indexer_batch_import_exact_kv_line
    io = StringIO.new
    logger = build_logger(io)

    payload = {
      collection: 'products',
      into: 'products_2025_10',
      batch_index: 3,
      docs_count: 10,
      success_count: 10,
      failure_count: 0,
      attempts: 1,
      http_status: 200,
      bytes_sent: 12_345
    }
    event = EventStub.new(payload, 45.6)

    SearchEngine::Notifications::CompactLogger.emit_batch_import(
      logger, Logger::INFO, event, format: :kv
    )

    expected = 'event=indexer.batch_import collection=products into=products_2025_10 '
    expected << 'batch_index=3 docs.count=10 success.count=10 failure.count=0 attempts=1 http_status=200 '
    expected << 'bytes.sent=12345 duration.ms=45.6'
    assert_equal "#{expected}\n", io.string
  end
end
