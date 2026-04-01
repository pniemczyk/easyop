module Users
  # Updates an existing user's profile.
  # Demonstrates:
  #   - before hook with a block (inline normalization)
  #   - ctx.merge! to enrich context after update
  class UpdateProfile < ApplicationOperation
    params do
      required :user, User
      optional :name,  :string
      optional :email, :string
    end

    # before hook with a block — inline normalization without a named method
    # Uses ctx[:key] (bracket access) for optional fields that may not be in ctx yet
    before do
      ctx.email = ctx[:email].to_s.strip.downcase if ctx[:email]
      ctx.name  = ctx[:name].to_s.strip            if ctx[:name]
    end

    rescue_from ActiveRecord::RecordInvalid do |e|
      ctx.fail!(error: "Could not update profile", errors: e.record.errors.to_h)
    end

    def call
      changes = {}
      changes[:email] = ctx[:email] if ctx[:email].present?
      changes[:name]  = ctx[:name]  if ctx[:name].present?

      ctx.user.update!(changes)

      # ctx.merge! — bulk-merge enriched data back into ctx
      ctx.merge!(updated_at: ctx.user.updated_at, changes_applied: changes.keys)
    end
  end
end
