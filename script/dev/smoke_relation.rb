#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))

require 'rails'
require 'search_engine'

# Minimal model for smoke
class SmokeProduct < SearchEngine::Base; end

r_1 = SmokeProduct.all
r_2 = r_1.where(category: 'milk')
r_3 = r_2.order(:name).limit(10)

ok = true

if r_1.equal?(r_2) || r_2.equal?(r_3)
  warn '[smoke:relation] chaining did not create new instances'
  ok = false
end

unless r_1.empty?
  warn '[smoke:relation] initial relation should be empty'
  ok = false
end

if r_2.empty?
  warn '[smoke:relation] relation with where should not be empty'
  ok = false
end

puts "r_1=#{r_1.inspect}"
puts "r_2=#{r_2.inspect}"
puts "r_3=#{r_3.inspect}"

exit(ok ? 0 : 1)
