# frozen_string_literal: true

begin
  require 'rspec/expectations'
rescue LoadError
  # RSpec not available; file remains loadable but inert in non-RSpec contexts
end

if defined?(RSpec)
  module SearchEngine
    # Test utilities namespace. Contains RSpec matchers for event assertions.
    module Test
      # Internal helpers to keep matcher block concise
      def self.emit_event_filter_by_name(events, name)
        case name
        when Regexp then events.select { |ev| ev[:name] =~ name }
        else events.select { |ev| ev[:name].to_s == name.to_s }
        end
      end

      def self.emit_event_payload_matches?(payload, matcher)
        if matcher.respond_to?(:matches?)
          matcher.matches?(payload)
        elsif matcher.is_a?(Proc)
          matcher.call(payload)
        else
          payload == matcher
        end
      rescue StandardError
        false
      end

      def self.emit_event_redact_for_message(payload)
        SearchEngine::Observability.redact(payload)
      rescue StandardError
        payload
      end

      def self.emit_event_failure_message(expected_name, payload_matcher, events)
        lines = []
        lines << "expected block to emit #{expected_name.inspect}"
        lines << "with payload matching: #{payload_matcher.inspect}" if payload_matcher
        if events && !events.empty?
          samples = events.take(3).map { |ev| emit_event_redact_for_message(ev[:payload]) }
          lines << "but got events: #{samples.inspect}"
        else
          lines << 'but no matching events were emitted'
        end
        lines.join("\n")
      end

      # RSpec matcher to assert that an event is emitted during a block.
      # Usage:
      #   expect { rel.to_a }.to emit_event('search_engine.search').with(hash_including(collection: 'products'))
      RSpec::Matchers.define :emit_event do |expected_name|
        supports_block_expectations

        chain :with do |payload_matcher|
          @payload_matcher = payload_matcher
        end

        match do |probe|
          captured = SearchEngine::Test.capture_events(/^search_engine\./) { probe.call }
          @events = SearchEngine::Test.emit_event_filter_by_name(captured, expected_name)
          return false if @events.empty?
          return true unless @payload_matcher

          @events.any? { |ev| SearchEngine::Test.emit_event_payload_matches?(ev[:payload], @payload_matcher) }
        end

        failure_message do
          SearchEngine::Test.emit_event_failure_message(expected_name, @payload_matcher, @events)
        end
      end
    end
  end
end
