# Simulates a payment gateway for development/demo purposes.
# Returns a realistic success or failure result with gateway metadata
# that gets captured in operation logs via the EasyOp Recording plugin.
#
# Success rate: 75% — set ENV["PAYMENT_SUCCESS_RATE"] (0.0–1.0) to override.
class FakePaymentGateway
  SUCCESS_RATE = (ENV.fetch("PAYMENT_SUCCESS_RATE", "0.75")).to_f

  DECLINE_SCENARIOS = [
    { code: "insufficient_funds",  message: "Your card has insufficient funds.",                    http_status: 402 },
    { code: "card_declined",       message: "Your card was declined by the issuer.",                http_status: 402 },
    { code: "expired_card",        message: "Your card has expired. Please use a different card.",  http_status: 402 },
    { code: "incorrect_cvc",       message: "The security code (CVC) you entered is incorrect.",    http_status: 402 },
    { code: "do_not_honor",        message: "Your card issuer declined this transaction.",           http_status: 402 },
    { code: "processing_error",    message: "A processing error occurred. Please try again.",       http_status: 500 },
    { code: "lost_card",           message: "This card has been reported lost.",                    http_status: 402 },
    { code: "velocity_exceeded",   message: "Too many recent transactions. Please try later.",      http_status: 429 },
  ].freeze

  CARD_NETWORKS = %w[visa mastercard amex discover].freeze

  Result = Struct.new(
    :success,
    :reference,
    :decline_code,
    :decline_message,
    :gateway_response,
    :latency_ms,
    keyword_init: true
  ) do
    def success? = success
    def failure? = !success
  end

  def self.charge(amount_cents:, email:, order_id: nil)
    new.charge(amount_cents: amount_cents, email: email, order_id: order_id)
  end

  def charge(amount_cents:, email:, order_id: nil)
    latency_ms = rand(120..480)
    sleep(latency_ms / 1000.0)

    if rand < SUCCESS_RATE
      build_success(amount_cents, email, order_id, latency_ms)
    else
      build_failure(amount_cents, email, order_id, latency_ms)
    end
  end

  private

  def build_success(amount_cents, email, order_id, latency_ms)
    reference = "PAY-#{SecureRandom.hex(8).upcase}"
    network   = CARD_NETWORKS.sample
    last4     = rand(1000..9999).to_s

    Result.new(
      success:   true,
      reference: reference,
      latency_ms: latency_ms,
      gateway_response: {
        status:      "succeeded",
        reference:   reference,
        amount:      amount_cents,
        currency:    "usd",
        email:       email,
        order_id:    order_id,
        network:     network,
        last4:       last4,
        processor:   "FakeStripe/v1",
        latency_ms:  latency_ms,
        timestamp:   Time.current.iso8601,
      }
    )
  end

  def build_failure(amount_cents, email, order_id, latency_ms)
    scenario = DECLINE_SCENARIOS.sample

    Result.new(
      success:         false,
      decline_code:    scenario[:code],
      decline_message: scenario[:message],
      latency_ms:      latency_ms,
      gateway_response: {
        status:       "failed",
        amount:       amount_cents,
        currency:     "usd",
        email:        email,
        order_id:     order_id,
        error_code:   scenario[:code],
        error_message: scenario[:message],
        http_status:  scenario[:http_status],
        processor:    "FakeStripe/v1",
        latency_ms:   latency_ms,
        timestamp:    Time.current.iso8601,
      }
    )
  end
end
