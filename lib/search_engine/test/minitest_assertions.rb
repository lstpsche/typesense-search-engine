# frozen_string_literal: true

module SearchEngine
  module Test
    # Minitest assertion helpers for SearchEngine event testing.
    #
    # Include this module in your test case to use `assert_emits` and `capture_events`.
    module MinitestAssertions
      # Assert that a named event is emitted within the provided block.
      # Optional payload matcher may be a Hash, Proc, or object responding to :matches?.
      # @param name [String, Regexp]
      # @param payload [Object, nil]
      # @yield block to execute
      def assert_emits(name, payload: nil, &block)
        captured = SearchEngine::Test.capture_events(/^search_engine\./, &block)
        matches = filter_by_name(captured, name)
        refute_empty(matches, "expected block to emit #{name.inspect}, but none matched")
        if payload
          ok = matches.any? { |ev| payload_matches?(ev[:payload], payload) }
          detail = matches.map { |e| e[:payload] }.inspect
          assert(ok, "expected an event payload matching #{payload.inspect}, got: #{detail}")
        end
        true
      end

      # Capture events emitted within the block and return the Array.
      # @yield block to execute
      # @return [Array<Hash>]
      def capture_events(&block)
        SearchEngine::Test.capture_events(/^search_engine\./, &block)
      end

      private

      def filter_by_name(events, name)
        case name
        when Regexp
          events.select { |ev| ev[:name] =~ name }
        else
          events.select { |ev| ev[:name].to_s == name.to_s }
        end
      end

      def payload_matches?(payload, matcher)
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
    end
  end
end
