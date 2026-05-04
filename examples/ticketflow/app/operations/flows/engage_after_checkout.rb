# frozen_string_literal: true

module Flows
  # Post-checkout email drip — Mode 2 (fire-and-forget, no subject).
  #
  # .call returns Ctx immediately; all three jobs are already scheduled in the
  # background before the controller issues its redirect.
  #
  # Step timings (relative to the moment .call is invoked):
  #   +2s  — booking confirmation  (wait: 2.seconds)
  #   +4s  — tickets ready notice  (wait: 4.seconds)
  #   +5m  — pre-event reminder    (wait_until: lambda evaluated at dispatch time)
  #
  # In production swap the wait_until lambda for a real calendar time, e.g.:
  #   wait_until: ->(ctx) { ctx.order.event.starts_at - 1.day }
  #
  # Contrast with Flows::FulfillOrder (Mode 3 — durable, subject :order):
  #   - FulfillOrder persists every step to DB and survives server restarts.
  #   - EngageAfterCheckout is lightweight: no DB rows, jobs live in memory.
  #     Use Mode 3 whenever durability or multi-day waits matter.
  class EngageAfterCheckout < ApplicationOperation
    include Easyop::Flow
    transactional false

    flow Notifications::SendBookingConfirmation.async(wait: 2.seconds),
         Notifications::SendTicketsReady.async(wait: 4.seconds),
         Notifications::SendPreEventReminder.async(wait_until: ->(_ctx) { 5.minutes.from_now })
  end
end
