namespace :easyop do
  desc "Run a demo of all EasyOp features"
  task demo: :environment do
    puts "\n=== EasyOp Feature Demo ===\n"

    # 1. Basic operation
    puts "\n1. Basic Operation:"
    result = Users::Register.call(email: "demo_#{Time.now.to_i}@example.com", name: "Demo User", password: "password123")
    puts result.success? ? "  ✓ Registered: #{result.user.email}" : "  ✗ #{result.error}"
    demo_user = result.user

    # 2. Instrumentation (logged automatically via subscriber)
    puts "\n2. Instrumentation: (check Rails log for [EasyOp] lines)"
    Users::Authenticate.call(email: demo_user&.email || "demo@example.com", password: "password123")

    # 3. Recording
    puts "\n3. Recording:"
    puts "  OperationLog count: #{OperationLog.count}"
    puts "  Last entry: #{OperationLog.last&.operation_name} — #{OperationLog.last&.success ? 'ok' : 'failed'}"

    # 4. Flow with skip_if + rollback
    puts "\n4. CompleteRegistration Flow:"
    result = Flows::CompleteRegistration.call(
      email: "flow_#{Time.now.to_i}@example.com", name: "Flow User",
      password: "password123", newsletter_opt_in: true
    )
    puts result.success? ? "  ✓ Flow ok, welcome article: #{result[:welcome_article]&.title}" : "  ✗ #{result.error}"

    # 5. Async enqueue
    puts "\n5. Async (enqueued, not executed in demo):"
    Newsletter::SendBroadcast.call_async(subject: "Hello World", body: "Test broadcast")
    puts "  ✓ Broadcast queued"

    # 6. Transactional
    puts "\n6. Transactional (ApplicationOperation wraps all ops in transactions):"
    plugins = ApplicationOperation._registered_plugins.map { |p| p[:plugin].name }
    puts "  Active plugins: #{plugins.join(', ')}"
    puts "  ✓ All operations above ran inside AR transactions"

    # 7. TransferCredits flow with transactional
    if demo_user
      puts "\n7. TransferCredits Flow (Transactional + Rollback):"
      demo_user.update!(credits: 100)
      recipient = User.where.not(id: demo_user.id).first
      if recipient
        result = Flows::TransferCredits.call(
          sender: demo_user, recipient: recipient, amount: 10, apply_fee: true
        )
        puts result.success? ? "  ✓ #{result.transfer_note}" : "  ✗ #{result.error}"
      else
        puts "  (skipped — need at least 2 users)"
      end
    end

    puts "\n=== Demo complete ===\n"
  end
end
