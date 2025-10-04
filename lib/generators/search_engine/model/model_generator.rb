# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/named_base'

begin
  require 'did_you_mean'
rescue LoadError
  # did_you_mean is optional; suggestions will be skipped if unavailable
end

module SearchEngine
  module Generators
    # Model generator that creates a minimal SearchEngine model mapping to a
    # Typesense collection.
    #
    # @example
    #   rails g search_engine:model Product --collection products --attrs id:integer name:string
    # @see docs/dx.md
    class ModelGenerator < Rails::Generators::NamedBase
      source_root File.expand_path('templates', __dir__)

      class_option :collection, type: :string, desc: 'Logical Typesense collection name (required)'
      class_option :attrs,
                   type: :string,
                   default: nil,
                   desc: 'Attribute declarations as key:type pairs (space/comma-separated)'

      def validate_options!
        return if options[:collection].to_s.strip.present?

        raise Thor::Error, '--collection is required. See docs/dx.md#generators--console-helpers'
      end

      def create_model
        @collection_name = options[:collection].to_s.strip
        @attributes = parse_attrs(options[:attrs])
        template 'model.rb.tt', File.join('app/models/search_engine', "#{file_name}.rb")
      end

      private

      ALLOWED_TYPES = %w[string integer float boolean datetime json].freeze

      def parse_attrs(raw)
        return [] if raw.nil?

        tokens = raw.split(/[\s,]+/).map(&:strip).reject(&:empty?)
        tokens.map do |pair|
          name, type = pair.split(':', 2)
          raise Thor::Error, "invalid attribute token: #{pair.inspect} (expected name:type)" unless name

          type = (type || 'string').to_s
          normalized = normalize_type(type)
          [name.to_s.underscore, normalized]
        end
      end

      def normalize_type(type)
        t = type.to_s.strip.downcase
        return t if ALLOWED_TYPES.include?(t)

        suggestion = suggest_type(t)
        hint = suggestion ? "; did you mean #{suggestion.inspect}?" : ''
        raise Thor::Error, "Unknown attribute type #{t.inspect}; allowed: #{ALLOWED_TYPES.join(', ')}#{hint}"
      end

      def suggest_type(token)
        return nil unless defined?(DidYouMean::SpellChecker)

        DidYouMean::SpellChecker.new(dictionary: ALLOWED_TYPES).correct(token).first
      end
    end
  end
end
