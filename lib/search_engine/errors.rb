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

    # Raised when a provided field name is unknown or disallowed for a model.
    #
    # Typical cause: a typo or using a field that is not declared via
    # {SearchEngine::Base.attribute}.
    class InvalidField < Error; end

    # Raised when a base attribute referenced by the Field Selection DSL is not
    # declared on the model.
    #
    # Prefer this over {InvalidField} for selection-time validation to provide
    # developer-friendly guidance and suggestions.
    class UnknownField < Error; end

    # Raised when an operator or fragment token is not recognized by the SQL-ish
    # grammar accepted by the Parser.
    class InvalidOperator < Error; end

    # Raised when a value cannot be coerced to the declared attribute type, or
    # when its shape is incompatible (e.g., empty array for IN/NOT IN).
    class InvalidType < Error; end

    # Raised when a requested join association is not declared for a model.
    #
    # Typical cause: a typo or referencing an association that has not been
    # registered via {SearchEngine::Base.join}.
    class UnknownJoin < Error; end

    # Raised when an association reference is invalid for the model and should
    # be declared via {SearchEngine::Base.join}.
    #
    # Prefer this for high-level validation messaging with guidance and
    # suggestions ("did you mean ..."), while keeping {UnknownJoin} for
    # lower-level registry lookups.
    class InvalidJoin < Error; end

    # Raised when a query references a joined association field without applying
    # the association on the relation via {SearchEngine::Relation#joins}.
    #
    # Example: calling `where(authors: { last_name: "Rowling" })` without
    # `.joins(:authors)` on the relation first.
    class JoinNotApplied < Error; end

    # Raised when a nested attribute referenced by the Field Selection DSL is
    # not declared on the joined association's target model.
    #
    # Typical cause: a typo in a nested field name or a stale attribute map.
    class UnknownJoinField < Error; end

    # Raised when selection inputs are malformed or ambiguous and cannot be
    # deterministically normalized (e.g., invalid nested shapes or incompatible
    # payload types).
    class ConflictingSelection < Error; end

    # Raised when grouping DSL is used with invalid inputs.
    #
    # Use for actionable messages like unknown field names, invalid limit values,
    # or non-boolean missing_values.
    #
    # @example Unknown field with suggestion
    #   raise SearchEngine::Errors::InvalidGroup, "InvalidGroup: unknown field :brand for grouping on SearchEngine::Product (did you mean :brand_id?)"
    class InvalidGroup < Error; end

    # Raised when grouping references unsupported constructs such as joined/path fields
    # (e.g., "$assoc.field"). Only base fields are supported for grouping.
    #
    # @example
    #   raise SearchEngine::Errors::UnsupportedGroupField, 'UnsupportedGroupField: grouping supports base fields only (got "$authors.last_name")'
    class UnsupportedGroupField < Error; end

    # Raised when strict selection is enabled and a requested field is absent
    # in the hydrated document (e.g., excluded by API mapping).
    #
    # This error is actionable and guides remediation: adjust the relation's
    # selection (select/exclude/reselect), relax strictness, or ensure the
    # upstream Typesense include/exclude mapping includes the fields.
    class MissingField < Error; end

    # Raised when a materializer requests fields that are not permitted by the
    # relation's effective selection (include − exclude, with exclude taking precedence).
    #
    # Used by selection-aware materializers like {SearchEngine::Relation#pluck}
    # and {SearchEngine::Relation#ids} to fail fast before any network call.
    class InvalidSelection < Error; end

    # Raised when curated ID does not match the configured pattern.
    #
    # @see docs/curation.md
    # @example
    #   raise SearchEngine::Errors::InvalidCuratedId, 'InvalidCuratedId: "foo bar" is not a valid curated ID. Expected pattern: /\A[\w\-:\.]+\z/. Try removing illegal characters.'
    class InvalidCuratedId < Error; end

    # Raised when pinned/hidden lists exceed configured limits after normalization.
    #
    # @see docs/curation.md
    # @example
    #   raise SearchEngine::Errors::CurationLimitExceeded, 'CurationLimitExceeded: pinned list exceeds max_pins=50 (attempted 51). Reduce inputs or raise the limit in SearchEngine.config.curation.'
    class CurationLimitExceeded < Error; end

    # Raised when an override tag is blank or invalid per allowed pattern.
    #
    # @see docs/curation.md
    # @example
    #   raise SearchEngine::Errors::InvalidOverrideTag, 'InvalidOverrideTag: "" is invalid. Use non-blank strings that match the allowed pattern.'
    class InvalidOverrideTag < Error; end
  end
end
