# frozen_string_literal: true

# SearchController renders federated multi-search results.
class SearchController < ApplicationController
  def multi
    q     = params[:q].to_s
    page  = (params[:page] || 1).to_i
    per   = (params[:per]  || 5).to_i

    prod = SearchEngine::Product.all
    prod = prod.where('name:~?', q) unless q.blank?
    prod = prod.page(page).per(per)

    br = SearchEngine::Brand.all
    br = br.where('name:~?', q) unless q.blank?
    br = br.page(page).per([per / 2, 1].max)

    @multi = SearchEngine.multi_search_result(common: { query_by: SearchEngine.config.default_query_by }) do |m|
      m.add :products, prod
      m.add :brands,   br
    end
  end
end
