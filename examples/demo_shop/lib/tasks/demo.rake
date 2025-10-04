# frozen_string_literal: true

namespace :demo do
  namespace :index do
    desc 'Apply schema and rebuild products index'
    task all: :environment do
      puts '[demo] Applying schema for products...'
      Rake::Task['search_engine:schema:apply'].invoke('products')
      puts '[demo] Done.'
    end
  end
end
