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

r_1 = SmokeProduct.all
r_2 = r_1.order(updated_at: :DESC)
r_3 = r_2.order('name:asc,updated_at:desc')
r_4 = r_3.select(:id, 'name', :name)
r_5 = r_4.limit(50).offset(200)
r_6 = r_5.page(2).per(20)

ok = true

if [r_2, r_3, r_4, r_5, r_6].any? { |r| r.equal?(r_1) }
  warn '[smoke:chainers] chaining did not create new instances'
  ok = false
end

puts "r_1=#{r_1.inspect}"
puts "r_2=#{r_2.inspect}"
puts "r_3=#{r_3.inspect}"
puts "r_4=#{r_4.inspect}"
puts "r_5=#{r_5.inspect}"
puts "r_6=#{r_6.inspect}"

exit(ok ? 0 : 1)
