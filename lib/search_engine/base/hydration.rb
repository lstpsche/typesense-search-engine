# frozen_string_literal: true

require 'active_support/concern'

module SearchEngine
  class Base
    # Hydration helpers for building instances from Typesense documents and
    # providing attribute readers and views.
    module Hydration
      extend ActiveSupport::Concern

      include SearchEngine::Base::DisplayCoercions

      class_methods do
        # Build a new instance from a Typesense document assigning only declared
        # attributes and capturing any extra keys in {#unknown_attributes}.
        #
        # Unknown keys are preserved as a String-keyed Hash to avoid symbol bloat.
        #
        # @param doc [Hash] a document as returned by Typesense
        # @return [Object] hydrated instance
        def from_document(doc)
          obj = new
          declared = attributes # { Symbol => type }
          declared_joins = begin
            self.class.respond_to?(:joins_config) ? (self.class.joins_config || {}) : {}
          rescue StandardError
            {}
          end
          unknown = {}

          # Build sets of hidden field names to strip from unknown attributes.
          begin
            attr_opts = respond_to?(:attribute_options) ? attribute_options : {}
          rescue StandardError
            attr_opts = {}
          end
          hidden_local = []
          attr_opts.each do |fname, opts|
            next unless opts.is_a?(Hash) && opts[:empty_filtering]

            hidden_local << "#{fname}_empty"
          end

          # For joined associations, hide $assoc.<field>_empty when target collection enabled it.
          hidden_join = []
          begin
            joins_cfg = self.class.respond_to?(:joins_config) ? self.class.joins_config : {}
            joins_cfg.each do |assoc_name, cfg|
              collection = cfg[:collection]
              next if collection.nil? || collection.to_s.strip.empty?

              begin
                target_klass = SearchEngine.collection_for(collection)
                next unless target_klass.respond_to?(:attribute_options)

                opts = target_klass.attribute_options || {}
                opts.each do |field_sym, o|
                  next unless o.is_a?(Hash) && o[:empty_filtering]

                  hidden_join << "$#{assoc_name}.#{field_sym}_empty"
                end
              rescue StandardError
                # Best-effort; skip when registry/metadata unavailable
              end
            end
          rescue StandardError
            # ignore
          end

          (doc || {}).each do |k, v|
            key_str = k.to_s
            key_sym = key_str.to_sym
            if declared.key?(key_sym)
              obj.instance_variable_set("@#{key_sym}", v)
            elsif declared_joins.key?(key_sym)
              # Hydrate join attribute as first-class reader
              obj.instance_variable_set("@#{key_sym}", v)
            else
              # Strip hidden fields from unknowns
              next if hidden_local.include?(key_str)
              next if hidden_join.include?(key_str)

              unknown[key_str] = v
              # Ensure the canonical document id is accessible as an instance
              # variable even when not declared via the DSL. Keep it in
              # unknowns for pretty-print rendering and debugging.
              obj.instance_variable_set('@id', v) if key_str == 'id'
            end
          end

          # Ensure default values for missing join attributes based on local_key type
          declared_joins.each do |assoc_name, cfg|
            ivar = "@#{assoc_name}"
            next if obj.instance_variable_defined?(ivar)

            lk = cfg[:local_key]
            lk_type = declared[lk]
            default_val = if lk_type.is_a?(Array) && lk_type.size == 1
                            []
                          else
                            nil
                          end
            obj.instance_variable_set(ivar, default_val)
          end

          obj.instance_variable_set(:@__unknown_attributes__, unknown.freeze) unless unknown.empty?
          obj
        end
      end

      # Return a shallow copy of unknown attributes captured during hydration.
      # Keys are Strings and values are as returned by the backend.
      # @return [Hash{String=>Object}]
      def unknown_attributes
        h = instance_variable_get(:@__unknown_attributes__)
        h ? h.dup : {}
      end

      # Return the document update timestamp coerced to Time.
      #
      # Prefers a declared attribute reader (when present). Falls back to the
      # unknown attributes payload (as returned by the backend) when the field
      # was not declared via the DSL. The value is coerced using the same logic
      # used for console rendering.
      #
      # @return [Time, nil]
      def doc_updated_at
        value = if instance_variable_defined?(:@doc_updated_at)
                  instance_variable_get(:@doc_updated_at)
                else
                  raw = instance_variable_get(:@__unknown_attributes__)
                  if raw&.key?('doc_updated_at')
                    raw['doc_updated_at']
                  elsif raw&.key?(:doc_updated_at)
                    raw[:doc_updated_at]
                  end
                end

        return nil if value.nil?

        __se_coerce_doc_updated_at_for_display(value)
      rescue StandardError
        nil
      end

      # Return a symbol-keyed Hash of attributes for this record.
      #
      # - Includes declared attributes in declaration order
      # - Ensures :doc_updated_at is present and coerced to Time when available
      # - Includes unknown fields under :unknown_attributes (String-keyed), with
      #   "doc_updated_at" removed to avoid duplication
      #
      # @return [Hash{Symbol=>Object}]
      def attributes
        declared = begin
          self.class.respond_to?(:attributes) ? self.class.attributes : {}
        rescue StandardError
          {}
        end

        out = {}

        declared.each_key do |name|
          val = instance_variable_get("@#{name}")
          out[name] =
            if name.to_s == 'doc_updated_at' && !val.nil?
              __se_coerce_doc_updated_at_for_display(val)
            else
              val
            end
        end

        raw_unknowns = instance_variable_get(:@__unknown_attributes__)
        unknowns = raw_unknowns ? raw_unknowns.dup : {}

        unless out.key?(:doc_updated_at)
          raw_val = unknowns['doc_updated_at']
          raw_val = unknowns[:doc_updated_at] if raw_val.nil?
          out[:doc_updated_at] = __se_coerce_doc_updated_at_for_display(raw_val) unless raw_val.nil?
        end

        # Remove duplicate source of doc_updated_at from nested unknowns
        unknowns.delete('doc_updated_at')
        unknowns.delete(:doc_updated_at)

        out[:unknown_attributes] = unknowns unless unknowns.empty?
        out
      end
    end
  end
end
