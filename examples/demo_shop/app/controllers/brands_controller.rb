# frozen_string_literal: true

# BrandsController lists brands for use in multi-search pairing.
class BrandsController < ApplicationController
  def index
    q     = params[:q].to_s
    page  = params[:page].presence || 1
    per   = params[:per].presence || 10

    rel = SearchEngine::Brand.all
    rel = rel.where('name:~?', q) unless q.blank?
    rel = rel.page(page.to_i).per(per.to_i)

    @relation = rel
    @result   = rel.to_a
  end
end
