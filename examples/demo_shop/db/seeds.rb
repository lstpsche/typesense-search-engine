# frozen_string_literal: true

# Seed via Docs::SeedDemo
begin
  require_relative '../lib/docs/seed_demo'
  Docs::SeedDemo.run
rescue LoadError
  # no-op when path not available
end
