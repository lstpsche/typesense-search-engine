# frozen_string_literal: true

module SearchEngine
  class Relation
    # Updating helpers bound to a relation instance.
    #
    # Provides `update_all` which updates documents that match the current
    # relation predicates. When no predicates are present, it updates all
    # documents from the collection by using a safe match-all filter.
    module Updating
      # Update all documents matching the current relation filters.
      #
      # When the relation has no filters, updates all documents from the
      # collection using a safe match-all filter (`id:!=null`).
      #
      # @param attributes [Hash, nil] fields to update (or pass as kwargs)
      # @param into [String, nil] override physical collection name
      # @param partition [Object, nil] partition token for resolvers
      # @param timeout_ms [Integer, nil] optional read timeout override in ms
      # @return [Integer] number of updated documents
      def update_all(attributes = nil, into: nil, partition: nil, timeout_ms: nil, **kwattrs)
        attrs = if attributes.is_a?(Hash) && !attributes.empty?
                  attributes
                elsif kwattrs && !kwattrs.empty?
                  kwattrs
                end
        raise ArgumentError, 'attributes must be a non-empty Hash' if attrs.nil? || attrs.empty?

        ast_nodes = Array(@state[:ast]).flatten.compact
        filter = compiled_filter_by(ast_nodes)
        filter = 'id:!=null' if filter.to_s.strip.empty?

        SearchEngine::Update.update_by(
          klass: @klass,
          attributes: attrs,
          filter: filter,
          into: into,
          partition: partition,
          timeout_ms: timeout_ms
        )
      end
    end
  end
end
