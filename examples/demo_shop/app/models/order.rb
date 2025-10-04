# frozen_string_literal: true

# Order AR model for demo orders.
class Order < ApplicationRecord
  has_many :order_items
end
