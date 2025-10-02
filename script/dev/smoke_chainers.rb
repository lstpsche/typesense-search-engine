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
  attribute :updated_at, :time
end

r1 = SmokeProduct.all
r2 = r1.order(updated_at: :DESC)
r3 = r2.order('name:asc,updated_at:desc')
r4 = r3.select(:id, 'name', :name)
r5 = r4.limit(50).offset(200)
r6 = r5.page(2).per(20)

ok = true

if [r2, r3, r4, r5, r6].any? { |r| r.equal?(r1) }
  warn '[smoke:chainers] chaining did not create new instances'
  ok = false
end

puts "r1=#{r1.inspect}"
puts "r2=#{r2.inspect}"
puts "r3=#{r3.inspect}"
puts "r4=#{r4.inspect}"
puts "r5=#{r5.inspect}"
puts "r6=#{r6.inspect}"

exit(ok ? 0 : 1)
