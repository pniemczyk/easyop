module Newsletter
  # Sends a broadcast email to all confirmed subscribers.
  # Demonstrates:
  #   - Flow step with rollback — destroys the Broadcast record if the flow fails
  #   - params schema with optional Article class type
  #   - ctx.merge! to enrich ctx with delivery counts
  class SendBroadcast < ApplicationOperation
    # This operation:
    #   - recording false      — skips OperationLog (broadcasts may contain sensitive content)
    #   - transactional false  — no DB transaction needed for broadcast sending (fire-and-forget)
    #   - Async-capable via parent: Newsletter::SendBroadcast.call_async(subject: ..., body: ...)
    recording false
    transactional false

    params do
      required :subject,    :string
      required :body,       :string
      optional :article,    Article
      optional :article_id, :integer
    end

    # Domain event: lets analytics/monitoring react to broadcasts without
    # coupling them to the send path.
    emits "broadcast.sent", on: :success,
          payload: ->(ctx) { { broadcast_id: ctx.broadcast_id, recipients_count: ctx.recipients_count } }

    rescue_from ActiveRecord::RecordInvalid do |e|
      ctx.fail!(error: "Could not create broadcast record", errors: e.record.errors.to_h)
    end

    def call
      # Support both article: object (sync) and article_id: integer (async)
      article = ctx.article || (ctx.article_id && Article.find_by(id: ctx.article_id))

      recipients = Subscription.where(unsubscribed_at: nil, confirmed: true)

      ctx.fail!(error: "No confirmed subscribers to send to") if recipients.none?

      broadcast = Broadcast.create!(
        subject:    ctx.subject,
        body:       ctx.body,
        article_id: article&.id,
        sent_at:    Time.current
      )

      ctx.broadcast = broadcast

      # Simulate sending emails (real app would use ActionMailer + deliver_later)
      recipients.each do |sub|
        Rails.logger.info "[Broadcast ##{broadcast.id}] Sending to #{sub.email}"
      end

      # ctx.merge! — enrich ctx with delivery metadata
      ctx.merge!(recipients_count: recipients.count, broadcast_id: broadcast.id)
    end

    # rollback — called by Flow when a later step fails
    # Cleans up the Broadcast record so we don't have orphaned sends
    def rollback
      ctx.broadcast&.destroy
      Rails.logger.warn "[Newsletter::SendBroadcast] Rolled back broadcast ##{ctx.broadcast&.id} due to flow failure"
    rescue StandardError => e
      Rails.logger.error "[Newsletter::SendBroadcast] Rollback error: #{e.message}"
    end
  end
end
