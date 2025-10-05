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

r_1 = SmokeProduct.all
r_2 = r_1.where(id: 5)
r_3 = r_2.where('brand_id:=[1,2,3]')
r_4 = r_3.where('price > ?', 100)

ok = true

if r_1.equal?(r_2) || r_2.equal?(r_3) || r_3.equal?(r_4)
  warn '[smoke:where] chaining did not create new instances'
  ok = false
end

if r_1.empty? == false && r_1.inspect.include?('filters=')
  warn '[smoke:where] initial relation should be empty'
  ok = false
end

# Peek into filters via inspect string (since state is internal). This is a heuristic sanity check.
puts "r_1=#{r_1.inspect}"
puts "r_2=#{r_2.inspect}"
puts "r_3=#{r_3.inspect}"
puts "r_4=#{r_4.inspect}"

exit(ok ? 0 : 1)
