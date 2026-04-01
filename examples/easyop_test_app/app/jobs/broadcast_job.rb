# Demonstrates: .call! with rescue Easyop::Ctx::Failure in a background job
class BroadcastJob < ApplicationJob
  queue_as :default

  def perform(article_id)
    article = Article.find(article_id)

    # .call! raises Easyop::Ctx::Failure instead of returning a failed ctx
    # Ideal for jobs where you want ActiveJob's retry/error reporting to kick in
    ctx = Newsletter::SendBroadcast.call!(
      subject: "New Article: #{article.title}",
      body:    article.body,
      article: article
    )

    Rails.logger.info "[BroadcastJob] Sent broadcast ##{ctx.broadcast_id} to #{ctx.recipients_count} subscriber(s)"
  rescue Easyop::Ctx::Failure => e
    # Log and let ActiveJob handle retry logic
    Rails.logger.error "[BroadcastJob] Broadcast failed: #{e.ctx.error}"
    raise e  # re-raise so ActiveJob marks the job as failed
  end
end
