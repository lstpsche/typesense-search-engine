# frozen_string_literal: true

Rails.application.routes.draw do
  get 'up' => 'rails/health#show', as: :rails_health_check

  resources :products, only: [:index]
  resources :brands,   only: [:index]
  resources :books,    only: [:index]

  get 'groups', to: 'groups#index'
  get 'search/multi', to: 'search#multi'

  root to: 'products#index'
end
