# frozen_string_literal: true

require 'active_support/concern'

module SearchEngine
  class Base
    # Default preset declaration and resolution.
    module Presets
      extend ActiveSupport::Concern

      class_methods do
        # Declare a default preset token for this collection.
        # @param name [#to_sym]
        # @return [void]
        def default_preset(name)
          raise ArgumentError, 'default_preset requires a name' if name.nil?

          token = name.to_sym
          raise ArgumentError, 'default_preset name must be non-empty' if token.to_s.strip.empty?

          instance_variable_set(:@__declared_default_preset__, token)
          nil
        end

        # Compute the effective default preset name for this collection.
        # @return [String, nil]
        def default_preset_name
          token = if instance_variable_defined?(:@__declared_default_preset__)
                    instance_variable_get(:@__declared_default_preset__)
                  end
          return nil if token.nil?

          presets_cfg = SearchEngine.config.presets
          if presets_cfg.enabled && presets_cfg.namespace
            +"#{presets_cfg.namespace}_#{token}"
          else
            token.to_s
          end
        end
      end
    end
  end
end
