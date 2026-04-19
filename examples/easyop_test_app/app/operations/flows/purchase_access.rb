# Demonstrates:
#   - Encryption in a multi-step flow (credit card encrypted in step 1's log)
#   - result_data chained across steps (payment from step 1 passed to step 2)
#   - transactional false: each step manages its own transaction
#   - Rollback: AccessGrant destroyed if a later failure occurs after Grant
#
# OperationLog tree after a successful purchase:
#   Flows::PurchaseAccess (root)
#     └─ Payments::Charge      params_data: { credit_card_number: { "$easyop_encrypted": "..." }, ... }
#                              result_data: { payment: { id: 1, class: "Payment" } }
#     └─ Access::Grant         params_data: { user: { id: 1, class: "User" }, payment: { id: 1, class: "Payment" } }
#                              result_data: { access_grant: { id: 1, class: "AccessGrant" } }
class Flows::PurchaseAccess < ApplicationOperation
  include Easyop::Flow
  transactional false

  flow Payments::Charge, Access::Grant
end
