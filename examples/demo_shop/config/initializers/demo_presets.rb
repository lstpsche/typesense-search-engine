# frozen_string_literal: true

# Optional preset namespace; keep enabled by default for demo
SearchEngine.configure do |c|
  c.presets.enabled = true
  c.presets.namespace = 'demo'
  # Keep default locked domains (filter_by, sort_by, include_fields, exclude_fields)
end
