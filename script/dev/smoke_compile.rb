#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))

require 'rails'
require 'search_engine'

# Minimal model for smoke
class SmokeProduct < SearchEngine::Base; end

cfg = SearchEngine.config
cfg.default_query_by ||= 'name,description'

r = SmokeProduct
    .all
    .where(active: true, brand_id: [1, 2])
    .order(updated_at: :desc)
    .select(:id, :name)
    .page(2).per(20)

puts "params=#{r.to_typesense_params.inspect}"

r2 = SmokeProduct
     .all
     .limit(50).offset(200)

puts "fallback_pagination=#{r2.to_typesense_params.inspect}"
