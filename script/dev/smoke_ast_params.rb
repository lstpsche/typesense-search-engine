# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'bundler/setup'
require 'search_engine'

class Product < SearchEngine::Base
  collection 'products_smoke'
  attribute :id, :integer
  attribute :active, :boolean
  attribute :price, :float
  attribute :brand_id, :integer
end

rel = Product.all
             .where(id: 1)
             .where(['price > ?', 100])
             .where('brand_id:=[1,2]')

puts "AST nodes: #{rel.ast.length}"
rel.ast.each_with_index do |node, idx|
  puts "  [#{idx}] #{node}"
end

params = rel.to_typesense_params
puts "filter_by: #{params[:filter_by]}"
