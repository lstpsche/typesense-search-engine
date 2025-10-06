# frozen_string_literal: true

module SearchEngine
  module Logging
    # Pure helpers for formatting compact log lines and fixed-width tables.
    # All methods are side-effect free and return strings/arrays only.
    module FormatHelpers
      DASH      = '—'
      ELLIPSIS  = '…'
      SPACE     = ' '
      KEY_VAL_SEP = '='
      PAIR_SEP    = ' '
      PIPE        = '|'

      module_function

      # Return EM dash when value is nil or empty?; otherwise return value as-is.
      def value_or_dash(value)
        return DASH if value.nil?
        return DASH if value.respond_to?(:empty?) && value.empty?

        value
      end

      # Return EM dash unless payload contains the key; when present, return the value or EM dash if nil.
      def display_or_dash(payload, key)
        return DASH unless payload.is_a?(Hash) && payload.key?(key)

        val = payload[key]
        val.nil? ? DASH : val
      end

      # Treats false and nil as missing; returns EM dash in these cases.
      def presence_or_dash(value)
        value || DASH
      end

      # Truncate text to width using a single-character ellipsis when overflowing.
      # Pads with spaces to reach width when shorter.
      def fixed_width(text, width, align: :left)
        s = text.to_s
        return s if width.nil? || width <= 0

        return s[0, [width - 1, 0].max] + ELLIPSIS if s.length > width

        pad_len = width - s.length
        case align
        when :right
          (' ' * pad_len) + s
        when :center
          left = pad_len / 2
          right = pad_len - left
          (' ' * left) + s + (' ' * right)
        else
          s + (' ' * pad_len)
        end
      end

      # Build a fixed-width table from rows (Array<Array<String>>)
      # widths: Array<Integer>; aligns: Array<Symbol> (:left, :right, :center)
      # Returns a single String with newline separators.
      def build_table(rows, widths, aligns: nil)
        return '' if rows.nil? || widths.nil?

        aligns ||= Array.new(widths.length, :left)

        lines = rows.map do |row|
          cols = row.each_with_index.map do |col, idx|
            fixed_width(col, widths[idx], align: aligns[idx])
          end
          cols.join(SPACE)
        end
        lines.join("\n")
      end

      # Serialize a Hash of key=>value pairs into a compact "k=v" line.
      # - Preserves insertion order
      # - Omits nil values
      def kv_compact(hash)
        return '' unless hash.is_a?(Hash)

        parts = []
        hash.each do |k, v|
          next if v.nil?

          parts << "#{k}#{KEY_VAL_SEP}#{v}"
        end
        parts.join(PAIR_SEP)
      end
    end
  end
end
