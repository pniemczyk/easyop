# Demonstrates a 4-step flow sharing one ctx:
#   1. Users::Register          — create user (params+result schema)
#   2. Newsletter::Subscribe    — subscribe if opted in (skip_if + lambda guard)
#   3. CreateWelcomeDraft       — create welcome article as a draft
#
# Also demonstrates:
#   - rollback: if any step fails after user creation, CreateWelcomeDraft rolls back
#   - lambda guard: Newsletter::Subscribe only runs when newsletter_opt_in is true
class Flows::CompleteRegistration < ApplicationOperation
  include Easyop::Flow
  transactional false

  # Nested operation defined before `flow` so it can be referenced in the step list.
  class CreateWelcomeDraft < ApplicationOperation
    # recording false  — this is an internal step, no need to log separately

    def call
      ctx.welcome_article = Article.create!(
        title:     "Welcome, #{ctx.user.name}!",
        body:      "This is your first article. Edit or delete it anytime.",
        user:      ctx.user,
        published: false
      )
    end

    def rollback
      ctx.welcome_article&.destroy
    end
  end

  flow Users::Register,
       ->(ctx) { ctx[:newsletter_opt_in] },
       Newsletter::Subscribe,
       CreateWelcomeDraft
end
