# frozen_string_literal: true

# Product AR model for demo products.
class Product < ApplicationRecord
  belongs_to :brand
end
