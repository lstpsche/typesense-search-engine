#!/usr/bin/env ruby

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))

require 'rails'
require 'search_engine'

# Smoke test for SearchEngine::Result hydration
module SearchEngine
  # Demo model used only by the smoke script
  class Product < Base
    collection 'products'
    attribute :id, :integer
    attribute :name, :string
  end
end

raw = {
  'found' => 2,
  'out_of' => 10,
  'facet_counts' => nil,
  'hits' => [
    { 'document' => { 'id' => 1, 'name' => 'Milk' } },
    { 'document' => { 'id' => 2, 'name' => 'Bread' } }
  ]
}

begin
  klass = SearchEngine.collection_for('products')
  result = SearchEngine::Result.new(raw, klass: klass)
  raise 'expected instances of Product' unless result.to_a.all? { |o| o.is_a?(SearchEngine::Product) }
  raise 'found mismatch' unless result.found == 2
  raise 'out_of mismatch' unless result.out_of == 10

  puts '[ok] Result hydrates with registered class'

  # Unknown collection => OpenStruct fallback
  unknown_raw = raw.dup
  unknown_res = SearchEngine::Result.new(unknown_raw, klass: nil)
  require 'ostruct'
  raise 'expected OpenStruct objects' unless unknown_res.to_a.all? { |o| o.is_a?(OpenStruct) }

  puts '[ok] Result hydrates with OpenStruct fallback'
rescue StandardError => error
  warn "[smoke] failure: #{error.class}: #{error.message}"
  exit 1
end
