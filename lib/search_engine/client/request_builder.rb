# frozen_string_literal: true

module SearchEngine
  class Client
    # RequestBuilder maps compiled params to concrete Typesense requests.
    # It has no network concerns; it only assembles the request object.
    class RequestBuilder
      # Normalized request container used by the transport adapter.
      # @!attribute http_method [Symbol] one of :get, :post, :put, :delete
      # @!attribute path [String] absolute path (no host), e.g. "/collections/products/documents/search"
      # @!attribute params [Hash] URL/common params (e.g., { use_cache:, cache_ttl: })
      # @!attribute headers [Hash] per-request headers (adapter may add global ones)
      # @!attribute body [Hash, nil] JSON body as a Ruby Hash
      # @!attribute body_json [String, nil] Deterministic JSON representation of body
      Request = Struct.new(:http_method, :path, :params, :headers, :body, :body_json, keyword_init: true)

      COLLECTIONS_PREFIX = '/collections/'
      DOCUMENTS_SEARCH_SUFFIX = '/documents/search'
      # Additional endpoint fragments for internal reuse
      COLLECTIONS_ROOT = '/collections'
      DOCUMENTS_SUFFIX = '/documents'
      DOCUMENTS_IMPORT_SUFFIX = '/documents/import'
      ALIASES_PREFIX = '/aliases/'
      SYNONYMS_SUFFIX = '/synonyms'
      SYNONYMS_PREFIX = '/synonyms/'
      STOPWORDS_SUFFIX = '/stopwords'
      STOPWORDS_PREFIX = '/stopwords/'
      HEALTH_PATH = '/health'

      CONTENT_TYPE_JSON = 'application/json'
      DEFAULT_HEADERS_JSON = { 'Content-Type' => CONTENT_TYPE_JSON }.freeze

      # Centralized doc links used by client error mapping
      DOC_CLIENT_ERRORS = 'docs/client.md#errors'

      INTERNAL_ONLY_KEYS = %i[
        _join
        _selection
        _preset_mode
        _preset_pruned_keys
        _preset_conflicts
        _curation_conflict_type
        _curation_conflict_count
        _runtime_flags
        _hits
        _curation
      ].freeze

      # Build a single-search request for a collection.
      # @param collection [String]
      # @param compiled_params [SearchEngine::CompiledParams]
      # @param url_opts [Hash]
      # @return [Request]
      def self.build_search(collection:, compiled_params:, url_opts: {})
        name = collection.to_s
        body_hash = sanitize_body_params(compiled_params.to_h)
        # Ensure deterministic ordering even after sanitization
        body_json = SearchEngine::CompiledParams.from(body_hash).to_json

        Request.new(
          http_method: :post,
          path: COLLECTIONS_PREFIX + name + DOCUMENTS_SEARCH_SUFFIX,
          params: url_opts || {},
          headers: DEFAULT_HEADERS_JSON,
          body: body_hash,
          body_json: body_json
        )
      end

      # Remove internal-only keys from the HTTP payload (copied from previous client behavior)
      # @param params [Hash]
      # @return [Hash]
      def self.sanitize_body_params(params)
        payload = params.dup
        INTERNAL_ONLY_KEYS.each { |k| payload.delete(k) }
        payload
      end
      private_class_method :sanitize_body_params
    end
  end
end
