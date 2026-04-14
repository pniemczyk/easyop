Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  root "events#index"

  resources :events, param: :slug, only: [ :index, :show ] do
    resources :checkouts, only: [ :new, :create ]
  end
  get "/orders/:order_id/confirmation", to: "checkouts#confirmation", as: :order_confirmation

  get  "/login",    to: "sessions#new",    as: :login
  post "/login",    to: "sessions#create"
  delete "/logout", to: "sessions#destroy", as: :logout

  get  "/register", to: "registrations#new",    as: :register
  post "/register", to: "registrations#create"

  namespace :admin do
    root "dashboard#index"
    resources :events do
      member { post :publish }
      resources :ticket_types, only: [ :create, :update, :destroy ]
    end
    resources :orders, only: [ :index, :show ] do
      member { post :refund }
    end
    resources :discount_codes, only: [ :index, :create, :destroy ]
    resources :operation_logs, only: [ :index, :show ]
  end
end
