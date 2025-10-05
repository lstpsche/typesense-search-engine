# frozen_string_literal: true

module SearchEngine
  class Relation
    module Dx
      # Pure helper for human-friendly rendering of Typesense filter strings.
      # Accepts a String and returns a transformed String without mutating input.
      module FriendlyWhere
        # Render a human-friendly `filter_by` string.
        # @param filter_by [String]
        # @return [String]
        def self.render(filter_by)
          s = filter_by.to_s
          return s if s.empty?

          s.gsub(' && ', ' AND ')
           .gsub(' || ', ' OR ')
           .gsub(':=[', ' IN [')
           .gsub(':!=[', ' NOT IN [')
        end
      end
    end
  end
end
