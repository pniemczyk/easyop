module Users
  # Registers a new user account.
  # Demonstrates:
  #   - params schema with :string, :boolean type shorthands
  #   - result schema
  #   - before hook (symbol)
  #   - rescue_from with block
  #   - ctx.slice to pass subset of ctx to AR create
  class Register < ApplicationOperation
    # params schema — type shorthands :string and :boolean
    params do
      required :email,    :string
      required :password, :string
      required :name,     :string
      optional :newsletter_opt_in, :boolean, default: false
    end

    # result schema — typed with User class
    result do
      required :user, User
    end

    # before hook (symbol) — normalizes email before validation/create
    before :normalize_email

    # rescue_from with block — wraps AR validation errors in ctx failure
    rescue_from ActiveRecord::RecordInvalid do |e|
      ctx.fail!(error: "Registration failed", errors: e.record.errors.to_h)
    end

    def call
      # ctx.slice extracts only the keys we want to pass to User.create!
      attrs = ctx.slice(:email, :name, :newsletter_opt_in)
        .merge(
          password:              ctx.password,
          password_confirmation: ctx.password
        )

      ctx.user = User.create!(attrs)
    end

    private

    def normalize_email
      ctx.email = ctx.email.to_s.strip.downcase
    end
  end
end
