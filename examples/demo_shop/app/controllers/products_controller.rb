# frozen_string_literal: true

# ProductsController demonstrates basic single-search and pagination.
class ProductsController < ApplicationController
  def index
    q     = params[:q].to_s
    page  = params[:page].presence || 1
    per   = params[:per].presence || 10

    rel = SearchEngine::Product.all
    rel = rel.where('name:~?', q) unless q.blank?
    rel = rel.page(page.to_i).per(per.to_i)

    @relation = rel
    @result   = rel.to_a
  end
end
