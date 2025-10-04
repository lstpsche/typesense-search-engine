# frozen_string_literal: true

# Author AR model with helper for full name.
class Author < ApplicationRecord
  has_many :books

  def full_name
    [first_name, last_name].compact.join(' ')
  end
end
