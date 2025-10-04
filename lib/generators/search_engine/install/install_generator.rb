# frozen_string_literal: true

require 'rails/generators'

module SearchEngine
  module Generators
    # Install generator that creates the initializer with ENV-based defaults.
    #
    # @example
    #   rails g search_engine:install
    # @see docs/dx.md
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)

      def create_initializer
        template 'initializer.rb.tt', 'config/initializers/search_engine.rb'
      end
    end
  end
end
