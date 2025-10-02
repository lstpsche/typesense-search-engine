#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))

require 'rails'
require 'search_engine'

# Minimal model for smoke
class SmokeProduct < SearchEngine::Base; end

r1 = SmokeProduct.all
r2 = r1.where(category: 'milk')
r3 = r2.order(:name).limit(10)

ok = true

if r1.equal?(r2) || r2.equal?(r3)
  warn '[smoke:relation] chaining did not create new instances'
  ok = false
end

unless r1.empty?
  warn '[smoke:relation] initial relation should be empty'
  ok = false
end

if r2.empty?
  warn '[smoke:relation] relation with where should not be empty'
  ok = false
end

puts "r1=#{r1.inspect}"
puts "r2=#{r2.inspect}"
puts "r3=#{r3.inspect}"

exit(ok ? 0 : 1)
