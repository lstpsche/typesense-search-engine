# frozen_string_literal: true

require 'test_helper'
require 'search_engine/otel'
require 'ostruct'

class OTelAdapterTest < Minitest::Test
  def setup
    # Ensure clean adapter state
    SearchEngine::OTel.stop! if defined?(SearchEngine::OTel)
  rescue StandardError
    nil
  end

  def test_installed_flag_reflects_sdk_presence
    return if defined?(OpenTelemetry::SDK)

    refute SearchEngine::OTel.installed?
  end

  def test_disabled_path_no_error
    SearchEngine.configure do |c|
      c.opentelemetry = OpenStruct.new(enabled: false, service_name: 'search_engine')
    end

    handle = SearchEngine::OTel.start!
    assert_nil handle

    # Emit a test event; should be a no-op for OTel
    result = SearchEngine::Instrumentation.instrument('search_engine.test.disabled', {}) { :ok }
    assert_equal :ok, result
  end

  def test_enabled_path_emits_spans_when_sdk_available
    skip 'OpenTelemetry SDK not available' unless defined?(OpenTelemetry::SDK)

    require 'opentelemetry/sdk'

    # In-memory exporter
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    span_processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    OpenTelemetry.tracer_provider.add_span_processor(span_processor)

    SearchEngine.configure do |c|
      c.opentelemetry = OpenStruct.new(enabled: true, service_name: 'search_engine')
    end

    SearchEngine::OTel.start!

    SearchEngine::Instrumentation.instrument('search_engine.search', collection: 'products') { :ok }

    spans = exporter.finished_spans
    assert_operator spans.size, :>=, 1
    names = spans.map(&:name)
    assert_includes names, 'search_engine.search'
  end
end
