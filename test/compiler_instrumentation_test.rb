# frozen_string_literal: true

require 'test_helper'

class CompilerInstrumentationTest < Minitest::Test
  class Product < SearchEngine::Base
    collection 'products_compiler_instrumentation'
    identify_by :id
    attribute :active, :boolean
  end

  def test_search_engine_compile_event_emitted
    ast = SearchEngine::AST.and_(SearchEngine::AST.eq(:active, true), SearchEngine::AST.eq(:id, 1))

    skip_unless_asn!

    received = []
    sub = ActiveSupport::Notifications.subscribe('search_engine.compile') do |*args|
      ev = ActiveSupport::Notifications::Event.new(*args)
      received << ev
    end

    begin
      compiled = SearchEngine::Compiler.compile(ast, klass: Product)
      refute_nil compiled
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    assert_equal 1, received.length
    payload = received.first.payload

    assert payload.key?(:node_count)
    assert payload.key?(:duration_ms)
    assert_equal 'products_compiler_instrumentation', payload[:collection]
    assert_equal 'CompilerInstrumentationTest::Product', payload[:klass]
    assert_instance_of Integer, payload[:node_count]
    assert payload[:duration_ms].to_f >= 0.0
    assert_equal :ast, payload[:source]
  end

  private

  def skip_unless_asn!
    skip 'ActiveSupport::Notifications not available' unless defined?(ActiveSupport::Notifications)
  end
end
