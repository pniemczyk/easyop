module Flows
  # Durable post-purchase communication flow for a paid order.
  #
  # Mode 3 (durable): `subject :order` makes .call return an EasyFlowRun instead
  # of Ctx. Each async step suspends the flow and schedules an EasyScheduledTask;
  # the Scheduler resumes it when `run_at` arrives.
  #
  # Contrast with Flows::Checkout (Mode 2 — no subject):
  #   - Checkout fires Tickets::DeliverTickets.async immediately and returns Ctx.
  #     The delivery job runs once and the flow is done.
  #   - FulfillOrder chains three async steps across time: immediate confirmation
  #     → 24h reminder → 48h post-event survey. Each step resumes from the
  #     persisted ctx (order, tickets, etc.) without reloading the whole request.
  #
  # Run via rake task:
  #   bin/rails easyop:fulfill_demo
  #
  # Or in a Rails console:
  #   order = Order.paid.first
  #   flow_run = Flows::FulfillOrder.call(order: order)
  #   flow_run.class   # => EasyFlowRun
  #   flow_run.status  # => "running"  (waiting for 24h reminder)
  #
  # To advance the scheduler immediately (dev/test only):
  #   Easyop::Scheduler.tick_now!
  class FulfillOrder < ApplicationOperation
    include Easyop::Flow
    transactional false

    subject :order   # triggers Mode 3 — .call returns EasyFlowRun

    # blocking: true — if SendOrderConfirmation exhausts all async_retry attempts,
    # the flow fails immediately and the downstream reminder + survey are skipped
    # (recorded as 'skipped' in EasyFlowRunStep so the audit trail is complete).
    flow Tickets::SendOrderConfirmation.async(blocking: true),
         Tickets::SendEventReminder.async(wait: 24.hours),
         Tickets::SendPostEventSurvey.async(wait: 48.hours)
  end
end
