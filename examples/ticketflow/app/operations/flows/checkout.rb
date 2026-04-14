module Flows
  # Inherits from ApplicationOperation so the flow itself is recorded in
  # operation_logs and appears as the root entry in the flow-tracing tree.
  # transactional false — steps manage their own transactions; EasyOp handles
  # soft rollback in reverse order on failure.
  class Checkout < ApplicationOperation
    include Easyop::Flow
    transactional false

    flow Orders::CalculateSubtotal,
         Orders::ApplyDiscount,
         Orders::CreateOrder,
         Orders::ProcessPayment,
         Tickets::GenerateTickets,
         Tickets::DeliverTickets
  end
end
