module Articles
  # Creates a new article, optionally publishing it immediately.
  # Demonstrates:
  #   - params schema with User class type and :boolean shorthand
  #   - result schema
  #   - rescue_from with block
  class Create < ApplicationOperation
    # params schema — mix of :string, :boolean shorthands and User class type
    params do
      required :title,   :string
      required :body,    :string
      required :user,    User
      optional :published, :boolean, default: false
    end

    # result schema
    result do
      required :article, Article
    end

    rescue_from ActiveRecord::RecordInvalid do |e|
      ctx.fail!(error: "Could not save article", errors: e.record.errors.to_h)
    end

    def call
      ctx.article = Article.create!(
        title:        ctx.title,
        body:         ctx.body,
        user:         ctx.user,
        published:    ctx.published,
        published_at: (Time.current if ctx.published)
      )
    end
  end
end
