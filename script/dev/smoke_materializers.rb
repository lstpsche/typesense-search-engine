#!/usr/bin/env ruby
# frozen_string_literal: true

# Smoke script for Relation materializers and memoization.
# Usage:
#   ruby script/dev/smoke_materializers.rb
#
# Requires a running Typesense and a collection registered in the host app.

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))

require 'rails'
require 'typesense'
require 'search_engine'
require 'search_engine/client'

SearchEngine.configure do |c|
  c.api_key = ENV['TYPESENSE_API_KEY'] if ENV['TYPESENSE_API_KEY']
  c.host = ENV['TYPESENSE_HOST'] || c.host
  c.port = (ENV['TYPESENSE_PORT'] || c.port).to_i
  c.protocol = ENV['TYPESENSE_PROTOCOL'] || c.protocol
  c.default_query_by ||= 'name'
end

module SearchEngine
  class Product < Base
    collection 'products'
    attribute :id, :string
    attribute :name, :string
  end
end

# Lightweight call counter for smoke output
module SECallCounter
  class << self
    attr_accessor :calls
  end
  self.calls = 0

  def search(collection:, params:, url_opts: {})
    SECallCounter.calls = (SECallCounter.calls || 0) + 1
    super
  end
end

SearchEngine::Client.prepend(SECallCounter)

rel = SearchEngine::Product.all.where("name:!='' ").limit(5)

puts "exists? (no memo) => #{rel.exists?} (calls=#{SECallCounter.calls})"
puts "count   (no memo) => #{rel.count} (calls=#{SECallCounter.calls})"

ary = rel.to_a
puts "to_a size          => #{ary.size} (calls=#{SECallCounter.calls})"
puts "ids                => #{rel.ids.inspect} (calls=#{SECallCounter.calls})"
puts "count (with memo)  => #{rel.count} (calls=#{SECallCounter.calls})"
puts "pluck(:name)       => #{rel.pluck(:name).inspect} (calls=#{SECallCounter.calls})"
