# frozen_string_literal: true

module SearchEngine
  # Public error hierarchy for the SearchEngine client wrapper.
  #
  # These exceptions provide a stable contract to callers regardless of the
  # underlying HTTP client or the Typesense gem's internal error types.
  module Errors
    # Base error for all SearchEngine failures.
    # @abstract
    class Error < StandardError; end

    # Raised when a request exceeds the configured timeout budget.
    #
    # Typical causes include connect/open timeouts or read timeouts surfaced by
    # the underlying HTTP client used by the official Typesense gem.
    class Timeout < Error; end

    # Raised for network-level connectivity issues prior to receiving a response.
    #
    # Examples: DNS resolution failures, refused TCP connections, TLS handshake
    # errors, or other socket-level errors.
    class Connection < Error; end

    # Raised when Typesense responds with a non-2xx HTTP status code.
    #
    # Carries the HTTP status and the parsed error body (when available) to aid
    # in debugging and programmatic handling upstream.
    class Api < Error
      # @return [Integer] HTTP status code
      attr_reader :status

      # @return [Object, nil] Parsed error body (Hash/String), when available
      attr_reader :body

      # @param msg [String]
      # @param status [Integer]
      # @param body [Object, nil]
      def initialize(msg, status:, body: nil)
        super(msg)
        @status = status
        @body = body
      end
    end

    # Raised when wrapper-level validation fails before making a request.
    #
    # Use this for actionable, developer-facing messages that indicate a caller
    # constructed an invalid request (e.g., blank collection name).
    class InvalidParams < Error; end
  end
end
