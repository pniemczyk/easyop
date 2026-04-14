Rails.application.routes.draw do
  root "articles#index"

  resources :articles do
    member { post :publish }
    resources :broadcasts, only: [:new, :create]
  end

  resource  :session,      only: [:new, :create, :destroy]
  resource  :registration, only: [:new, :create]
  resources :subscriptions,    only: [:new, :create, :destroy]
  resources :operation_logs,   only: [:index]
  resources :event_logs,       only: [:index]
  resources :transfers,        only: [:new, :create]

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check
end
