module Flows
  # Publishes an article and broadcasts it to all newsletter subscribers.
  # Demonstrates:
  #   - Flow with sequential steps + shared ctx
  #   - rollback: if SendBroadcast succeeds but something later fails,
  #     or if SendBroadcast itself fails, the broadcast is rolled back
  #   - In practice: Articles::Publish sets ctx.article; SendBroadcast
  #     reads ctx.article, ctx.subject, and ctx.body from the same ctx
  class PublishAndBroadcast
    include Easyop::Flow

    flow Articles::Publish,
         Newsletter::SendBroadcast
  end
end
