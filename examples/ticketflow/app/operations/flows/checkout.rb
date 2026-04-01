module Flows
  class Checkout
    include Easyop::Flow

    flow Orders::CalculateSubtotal,
         Orders::ApplyDiscount,
         Orders::CreateOrder,
         Orders::ProcessPayment,
         Tickets::GenerateTickets,
         Tickets::DeliverTickets
  end
end
