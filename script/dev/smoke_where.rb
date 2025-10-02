#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))

require 'rails'
require 'search_engine'

# Minimal model for smoke
class SmokeProduct < SearchEngine::Base
  attribute :id, :integer
  attribute :brand_id, :integer
  attribute :price, :float
  attribute :name, :string
end

r1 = SmokeProduct.all
r2 = r1.where(id: 5)
r3 = r2.where('brand_id:=[1,2,3]')
r4 = r3.where('price > ?', 100)

ok = true

if r1.equal?(r2) || r2.equal?(r3) || r3.equal?(r4)
  warn '[smoke:where] chaining did not create new instances'
  ok = false
end

if r1.empty? == false && r1.inspect.include?('filters=')
  warn '[smoke:where] initial relation should be empty'
  ok = false
end

# Peek into filters via inspect string (since state is internal). This is a heuristic sanity check.
puts "r1=#{r1.inspect}"
puts "r2=#{r2.inspect}"
puts "r3=#{r3.inspect}"
puts "r4=#{r4.inspect}"

exit(ok ? 0 : 1)
