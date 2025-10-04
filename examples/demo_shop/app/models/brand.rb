# frozen_string_literal: true

# Brand AR model for demo brands.
class Brand < ApplicationRecord
  has_many :products
  validates :name, presence: true
end
