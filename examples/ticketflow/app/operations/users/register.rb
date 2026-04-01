module Users
  class Register < ApplicationOperation
    params do
      required :email, String
      required :name, String
      required :password, String
      required :password_confirmation, String
    end

    def call
      ctx.fail!(error: "Passwords do not match") unless ctx.password == ctx.password_confirmation
      ctx.fail!(error: "Email already taken") if User.exists?(email: ctx.email.downcase)

      ctx.user = User.create!(
        email: ctx.email.downcase,
        name: ctx.name,
        password: ctx.password,
        password_confirmation: ctx.password_confirmation
      )
    end
  end
end
