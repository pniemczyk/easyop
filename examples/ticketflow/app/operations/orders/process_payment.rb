module Orders
  class ProcessPayment < ApplicationOperation
    # Capture payment outcome in result_data for audit and debugging.
    # On success: payment_reference + latency. On failure: decline_code.
    record_result { |ctx| { payment_reference: ctx[:payment_reference], payment_latency_ms: ctx[:payment_latency_ms], decline_code: ctx[:payment_decline_code] }.compact }

    def call
      gateway_result = FakePaymentGateway.charge(
        amount_cents: ctx.order.total_cents,
        email:        ctx.order.email,
        order_id:     ctx.order.id
      )

      # Store full gateway response in ctx so the Recording plugin captures
      # all payment details in operation_logs.params_data
      ctx.payment_gateway_response = gateway_result.gateway_response
      ctx.payment_latency_ms       = gateway_result.latency_ms
      ctx.payment_success          = gateway_result.success?

      if gateway_result.success?
        ctx.payment_reference = gateway_result.reference

        ctx.order.update!(
          status:                   "paid",
          payment_reference:        gateway_result.reference,
          payment_gateway_response: gateway_result.gateway_response.to_json,
          paid_at:                  Time.current
        )

        ctx.order.order_items.each { |item| item.ticket_type.increment!(:sold_count, item.quantity) }
        ctx.order.reload.discount_code&.increment!(:use_count)
      else
        ctx.payment_decline_code = gateway_result.decline_code

        ctx.fail!(
          error:            gateway_result.decline_message,
          payment_declined: true,
          decline_code:     gateway_result.decline_code
        )
      end
    end

    def rollback
      ctx.order&.update(status: "pending", payment_reference: nil, paid_at: nil,
                        payment_gateway_response: nil)
      ctx.order&.order_items&.each { |item| item.ticket_type.decrement!(:sold_count, item.quantity) }
      ctx.order&.discount_code&.decrement!(:use_count)
    end
  end
end
