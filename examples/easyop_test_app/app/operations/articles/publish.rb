module Articles
  # Publishes a draft article.
  # Demonstrates:
  #   - after hook with a block (logging)
  #   - rescue_from with block
  class Publish < ApplicationOperation
    params do
      required :article, Article
    end

    result do
      required :article, Article
    end

    # after hook with a block — fires after call completes (even on success path)
    after { Rails.logger.info "[Articles::Publish] Article ##{ctx.article&.id} published at #{Time.current}" }

    rescue_from ActiveRecord::RecordInvalid do |e|
      ctx.fail!(error: "Could not publish article", errors: e.record.errors.to_h)
    end

    def call
      ctx.fail!(error: "Article already published") if ctx.article.published?
      ctx.article.update!(published: true, published_at: Time.current)
    end
  end
end
