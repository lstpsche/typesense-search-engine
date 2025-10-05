# frozen_string_literal: true

module SearchEngine
  class Client
    # HttpAdapter is a minimal transport wrapper around the injected Typesense::Client.
    # It has no Typesense domain knowledge beyond executing the provided request.
    class HttpAdapter
      Response = Struct.new(:status, :headers, :body, keyword_init: true)

      TYPESENSE_API_KEY_HEADER = 'X-TYPESENSE-API-KEY'

      # @param typesense_client [Object] an instance compatible with Typesense::Client
      def initialize(typesense_client)
        @typesense = typesense_client
      end

      # Execute a normalized request. Returns a normalized Response with raw body.
      # Note: This adapter delegates to high-level Typesense client helpers where available
      # to avoid re-implementing HTTP plumbing. It stays transport-only and does not parse.
      #
      # Supported shapes used by current client:
      # - POST /collections/:c/documents/search with common_params URL opts
      #
      # @param request [SearchEngine::Client::RequestBuilder::Request]
      # @return [Response]
      def perform(request)
        method = request.http_method.to_sym
        path = request.path.to_s
        if method == :post && path.match?(%r{\A/collections/[^/]+/documents/search\z})
          collection = path.split('/')[2]
          raw = @typesense.collections[collection].documents.search(request.body, common_params: request.params)
          # The official client returns parsed JSON (Hash). No headers/status exposed here.
          return Response.new(status: 200, headers: {}, body: raw)
        end

        # Fallback: attempt a generic call via low-level typesense endpoint access if available.
        # This keeps adapter permissive for future endpoints without adding Faraday here.
        raise ArgumentError, "Unsupported request path for adapter: #{request.method} #{request.path}"
      end
    end
  end
end
