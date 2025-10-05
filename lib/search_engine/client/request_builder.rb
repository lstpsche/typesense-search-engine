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
      CONTENT_TYPE_JSON = 'application/json'

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
          headers: { 'Content-Type' => CONTENT_TYPE_JSON },
          body: body_hash,
          body_json: body_json
        )
      end

      # Remove internal-only keys from the HTTP payload (copied from previous client behavior)
      # @param params [Hash]
      # @return [Hash]
      def self.sanitize_body_params(params)
        payload = params.dup
        payload.delete(:_join)
        payload.delete(:_selection)
        payload.delete(:_preset_mode)
        payload.delete(:_preset_pruned_keys)
        payload.delete(:_preset_conflicts)
        payload.delete(:_curation_conflict_type)
        payload.delete(:_curation_conflict_count)
        payload.delete(:_runtime_flags)
        payload.delete(:_hits)
        payload
      end
      private_class_method :sanitize_body_params
    end
  end
end
