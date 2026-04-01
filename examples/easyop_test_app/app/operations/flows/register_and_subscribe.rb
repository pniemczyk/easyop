module Flows
  # Registers a new user and optionally subscribes them to the newsletter.
  # Demonstrates:
  #   - Flow with sequential steps sharing a single ctx
  #   - Lambda guard in flow: -> (ctx) { ... } guards Newsletter::Subscribe
  #     (only runs if user opted in — first layer of protection)
  #   - Newsletter::Subscribe also has skip_if for double-guard safety
  class RegisterAndSubscribe
    include Easyop::Flow

    flow Users::Register,
         # Lambda guard — Newsletter::Subscribe only runs if newsletter_opt_in is truthy
         ->(ctx) { ctx.newsletter_opt_in },
         Newsletter::Subscribe
  end
end
