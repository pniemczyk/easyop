module Users
  # Authenticates a user by email and password.
  # Demonstrates:
  #   - params schema with :string type shorthands
  #   - before hook (symbol) for email normalization
  #   - rescue_from with: :symbol (named method handler for RecordNotFound)
  class Authenticate < ApplicationOperation
    # Read-only operation — no DB writes, no transaction needed
    transactional false

    params do
      required :email,    :string
      required :password, :string
    end

    # before hook (symbol) — normalize before DB lookup
    before :normalize_email

    # rescue_from with: :symbol — delegates to a named instance method
    # Fired when User.find_by! raises ActiveRecord::RecordNotFound
    rescue_from ActiveRecord::RecordNotFound, with: :handle_not_found

    def call
      # find_by! raises RecordNotFound — caught by rescue_from above
      user = User.find_by!(email: ctx.email)
      ctx.fail!(error: "Invalid email or password") unless user.authenticate(ctx.password)
      ctx.user = user
    end

    private

    def normalize_email
      ctx.email = ctx.email.to_s.strip.downcase
    end

    def handle_not_found(_e)
      ctx.fail!(error: "Invalid email or password")
    end
  end
end
