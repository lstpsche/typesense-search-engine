# frozen_string_literal: true

# BooksController shows JOINs with authors and nested selection.
class BooksController < ApplicationController
  def index
    q     = params[:q].to_s
    page  = params[:page].presence || 1
    per   = params[:per].presence || 10

    rel = SearchEngine::Book.all
    rel = rel.joins(:authors)
    rel = rel.include_fields(:id, :title, authors: %i[first_name last_name])

    # Example JOIN filter (e.g., last_name = "Rowling")
    rel = rel.where(authors: { last_name: q }) unless q.blank?
    rel = rel.page(page.to_i).per(per.to_i)

    @relation = rel
    @result   = rel.to_a
  end
end
