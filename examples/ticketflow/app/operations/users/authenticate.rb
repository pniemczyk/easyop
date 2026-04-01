module Users
  class Authenticate < ApplicationOperation
    recording false # don't log passwords

    params do
      required :email, String
      required :password, String
    end

    def call
      user = User.find_by(email: ctx.email.downcase)
      ctx.fail!(error: "Invalid email or password") unless user&.authenticate(ctx.password)
      ctx.user = user
    end
  end
end
