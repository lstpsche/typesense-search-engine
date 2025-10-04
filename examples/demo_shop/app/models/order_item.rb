# frozen_string_literal: true

# OrderItem AR model for items in an order.
class OrderItem < ApplicationRecord
  belongs_to :order
  belongs_to :product
end
