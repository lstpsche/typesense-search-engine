# frozen_string_literal: true

# Book AR model for demo books.
class Book < ApplicationRecord
  belongs_to :author
end
