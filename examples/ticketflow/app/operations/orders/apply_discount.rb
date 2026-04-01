module Orders
  class ApplyDiscount < ApplicationOperation
    skip_if { |ctx| ctx.coupon_code.to_s.strip.empty? }

    def call
      discount_code = DiscountCode.find_by(code: ctx.coupon_code.to_s.strip.upcase)
      ctx.fail!(error: "Discount code not found or expired") unless discount_code&.valid_for_use?

      ctx.discount_cents = discount_code.calculate_discount(ctx.subtotal_cents)
      ctx.discount_code = discount_code
    end
  end
end
