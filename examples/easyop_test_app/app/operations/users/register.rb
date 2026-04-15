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

    # params_data (automatic): records the INPUT keys — email, name,
    #   newsletter_opt_in, password (replaced with [FILTERED]). The ctx.user
    #   object created during #call is NOT in params_data.
    #
    # result_data: capture the full output ctx so auditors can see which User
    #   was created (serialized as {id:, class:}) and all ctx values after the
    #   call completes — the complement of params_data.
    record_result true

    # Domain event: fired on successful registration so downstream handlers
    # (welcome emails, analytics, etc.) can react without coupling to this class.
    emits "user.registered", on: :success,
          payload: ->(ctx) { { user_id: ctx.user.id, email: ctx.user.email,
                               newsletter_opt_in: ctx.user.newsletter_opt_in } }

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
