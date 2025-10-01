#!/usr/bin/env ruby

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))

require 'rails'
require 'search_engine'

# Smoke test for SearchEngine::Base macros and registry
module SearchEngine
  # Smoke model: base item
  class Item < Base
    attribute :name, :string
  end

  # Smoke model: product overriding attribute type and registering collection
  class Product < Item
    collection 'products'
    attribute :id, :integer
    attribute :name, :text
  end
end

begin
  # Resolve by collection
  resolved = SearchEngine.collection_for('products')
  unless resolved == SearchEngine::Product
    warn "[smoke] expected SearchEngine::Product, got #{resolved}"
    exit 1
  end

  # Inheritance and override check
  attrs_item = SearchEngine::Item.attributes
  attrs_product = SearchEngine::Product.attributes

  unless attrs_item[:name] == :string
    warn "[smoke] expected Item.name to be :string, got #{attrs_item[:name].inspect}"
    exit 1
  end

  unless attrs_product[:name] == :text && attrs_product[:id] == :integer
    warn "[smoke] Product attributes incorrect: #{attrs_product.inspect}"
    exit 1
  end

  puts '[ok] registry and base macros operational'
rescue StandardError => error
  warn "[smoke] failure: #{error.class}: #{error.message}"
  exit 1
end
