# frozen_string_literal: true

# GroupsController renders grouped product results by brand.
class GroupsController < ApplicationController
  def index
    page  = (params[:page] || 1).to_i
    per   = (params[:per]  || 10).to_i

    rel = SearchEngine::Product
          .all
          .group_by(:brand_id, limit: 1, missing_values: true)
          .page(page)
          .per(per)

    @relation = rel
    @result   = rel.execute
  end
end
