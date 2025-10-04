# frozen_string_literal: true

module SearchEngine
  # Admin namespace for management APIs (synonyms/stopwords).
  #
  # Provides thin, validated wrappers over Typesense admin endpoints and
  # emits structured instrumentation. Pure stdlib + typesense gem only.
  module Admin; end
end

require 'search_engine/admin/synonyms'
require 'search_engine/admin/stopwords'
