# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'search_engine'

class Product < SearchEngine::Base
  collection 'products_smoke'
  attribute :id, :integer
  attribute :name, :string
  attribute :active, :boolean
  attribute :price, :float
end

rel = Product.all
puts 'Base:'
pp rel.to_typesense_params

rel = rel.select(:id, :name)
puts 'After select(:id, :name):'
pp rel.to_typesense_params

rel = rel.reselect(:name)
puts 'After reselect(:name):'
pp rel.to_typesense_params

rel = rel.where(id: 1).where(['price > ?', 100])
puts 'After where(id: 1).where(["price > ?", 100]):'
pp rel.to_typesense_params

rel = rel.rewhere(active: true)
puts 'After rewhere(active: true):'
pp rel.to_typesense_params

rel = rel.order(name: :asc)
puts 'After order(name: :asc):'
pp rel.to_typesense_params

rel = rel.unscope(:order, :where)
puts 'After unscope(:order, :where):'
pp rel.to_typesense_params
