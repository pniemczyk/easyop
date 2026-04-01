module Admin
  class DiscountCodesController < BaseController
    def index
      @discount_codes = DiscountCode.order(created_at: :desc)
    end

    def create
      DiscountCode.create!(discount_code_params.merge(code: discount_code_params[:code].upcase))
      redirect_to admin_discount_codes_path, notice: "Discount code created!"
    rescue => e
      redirect_to admin_discount_codes_path, alert: e.message
    end

    def destroy
      DiscountCode.find(params[:id]).destroy
      redirect_to admin_discount_codes_path, notice: "Discount code deleted."
    end

    private

    def discount_code_params
      params.require(:discount_code).permit(:code, :discount_type, :amount, :max_uses, :expires_at)
    end
  end
end
