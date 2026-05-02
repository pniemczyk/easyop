module Flows
  # Inherits from ApplicationOperation so the flow itself is recorded in
  # operation_logs and appears as the root entry in the flow-tracing tree.
  # transactional false — steps manage their own transactions; EasyOp handles
  # soft rollback in reverse order on failure.
  #
  # Demonstrates Mode 2 (fire-and-forget async):
  #   - Steps 1-5 run synchronously (order committed, tickets generated)
  #   - Tickets::DeliverTickets is enqueued via ActiveJob immediately after
  #     GenerateTickets completes — the user gets a response before the email lands
  #
  # To upgrade to Mode 3 (durable, with retry): add `subject :order` and
  # `require "easyop/persistent_flow"` to config/initializers/easyop.rb.
  # Then `.call` returns a FlowRun instead of Ctx.
  class Checkout < ApplicationOperation
    include Easyop::Flow
    transactional false

    flow Orders::CalculateSubtotal,
         Orders::ApplyDiscount,
         Orders::CreateOrder,
         Orders::ProcessPayment,
         Tickets::GenerateTickets,
         Tickets::DeliverTickets.async   # Mode 2: enqueued after tickets generated
  end
end
