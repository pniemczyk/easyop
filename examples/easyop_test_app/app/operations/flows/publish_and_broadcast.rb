module Flows
  # Publishes an article and broadcasts it to all newsletter subscribers.
  # Demonstrates:
  #   - Mode 2 (fire-and-forget async): Articles::Publish runs synchronously;
  #     Newsletter::SendBroadcast is enqueued as a background job immediately after
  #     (the flow returns Ctx without waiting for the broadcast to complete).
  #   - Flow with sequential steps + shared ctx
  #   - In practice: Articles::Publish sets ctx.article; SendBroadcast
  #     reads ctx.article, ctx.subject, and ctx.body from the same ctx
  #
  # Note: Newsletter::SendBroadcast inherits plugin Easyop::Plugins::Async from
  # ApplicationOperation, which enables the .async step modifier.
  class PublishAndBroadcast < ApplicationOperation
    include Easyop::Flow
    transactional false

    flow Articles::Publish,
         Newsletter::SendBroadcast.async   # Mode 2: enqueued immediately, flow continues
  end
end
