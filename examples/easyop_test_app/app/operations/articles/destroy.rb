module Articles
  # Destroys an article owned by the given user.
  # Demonstrates:
  #   - params schema with :integer type shorthand
  #   - rescue_from with: :symbol (named method handler for RecordNotFound)
  #   - ctx.merge! to write back result data
  class Destroy < ApplicationOperation
    params do
      required :article_id, :integer
      required :user,       User
    end

    # rescue_from with: :symbol — handles AR not-found with a named method
    rescue_from ActiveRecord::RecordNotFound, with: :handle_not_found

    def call
      # Scoped to the current user — raises RecordNotFound if not owned
      article = ctx.user.articles.find(ctx.article_id)
      article.destroy!

      # ctx.merge! — bulk-merge result data into ctx
      ctx.merge!(deleted_article_id: ctx.article_id, deleted_title: article.title)
    end

    private

    def handle_not_found(_e)
      ctx.fail!(error: "Article not found or access denied")
    end
  end
end
