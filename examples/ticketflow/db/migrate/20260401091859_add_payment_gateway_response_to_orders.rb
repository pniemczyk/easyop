class AddPaymentGatewayResponseToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :payment_gateway_response, :text
  end
end
