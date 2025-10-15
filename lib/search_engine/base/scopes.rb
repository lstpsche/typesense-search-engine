# frozen_string_literal: true

require 'active_support/concern'

module SearchEngine
  class Base
    # ActiveRecord-like named scopes for SearchEngine models.
    #
    # Scopes are defined on the model class and must return a
    # {SearchEngine::Relation}. They are evaluated against a fresh
    # relation (`all`) and are therefore fully chainable.
    #
    # Examples:
    #   class Product < SearchEngine::Base
    #     scope :active, -> { where(active: true) }
    #     scope :by_store, ->(id) { where(store_id: id) }
    #   end
    #
    #   Product.active.by_store(1).search("shoes")
    module Scopes
      extend ActiveSupport::Concern

      class_methods do
        # Define a named, chainable scope.
        #
        # @param name [#to_sym] public method name for the scope
        # @param body [#call, nil] a Proc/lambda evaluated against a fresh Relation
        # @yield evaluated as the scope body when +body+ is nil (AR-style)
        # @return [void]
        #
        # The scope body is executed with `self` set to a fresh
        # {SearchEngine::Relation} bound to the model. It must return a
        # Relation (or nil, which is treated as `all`).
        def scope(name, body = nil, &block)
          raise ArgumentError, 'scope requires a name' if name.nil?

          impl = body || block
          raise ArgumentError, 'scope requires a callable (Proc/lambda)' if impl.nil? || !impl.respond_to?(:call)

          method_name = name.to_sym

          define_singleton_method(method_name) do |*args, **kwargs, &_unused_block|
            base = all
            result = base.instance_exec(*args, **kwargs, &impl)

            return base if result.nil?
            return result if result.is_a?(SearchEngine::Relation)

            raise ArgumentError,
                  "scope :#{method_name} must return a SearchEngine::Relation (got #{result.class})"
          end

          nil
        end
      end
    end
  end
end
