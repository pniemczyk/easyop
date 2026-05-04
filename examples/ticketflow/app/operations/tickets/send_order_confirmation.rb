module Tickets
  # Sends the order confirmation immediately after the order is placed.
  # In production: email the receipt and ticket PDF. Here: stamps a timestamp.
  #
  # Retry policy: SMTP / mailer jobs are transient — up to 3 total attempts with
  # exponential backoff before giving up.  Declared here so every flow that uses
  # this operation inherits the policy automatically.
  #
  # Demo failure simulation:
  #   Tickets::SendOrderConfirmation.simulate_failures!(2)  # fail next 2 calls
  class SendOrderConfirmation < ApplicationOperation
    # Allow raw exceptions to propagate so the durable-flow Runner can retry them.
    # ApplicationOperation's base rescue_from converts all StandardErrors to
    # ctx.fail!, which would bypass async_retry.  This override re-raises so the
    # runner sees the real exception and applies the retry policy instead.
    rescue_from StandardError do |e|
      raise e
    end

    async_retry max_attempts: 3, wait: 5, backoff: :exponential

    @@_simulated_failures = 0

    def self.simulate_failures!(count)
      @@_simulated_failures = count
    end

    def self.reset_simulation!
      @@_simulated_failures = 0
    end

    def call
      if @@_simulated_failures > 0
        remaining = @@_simulated_failures -= 1
        raise "Simulated SMTP error (#{remaining} more failure#{'s' if remaining != 1} queued)"
      end

      ctx.confirmation_sent_at = Time.current
      Rails.logger.info "[SendOrderConfirmation] Confirmation sent for order ##{ctx.order.id}"
    end
  end
end
