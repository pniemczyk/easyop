# Seeds — idempotent, safe to run multiple times.
# Creates realistic test data for every feature in the app.
#
# Login credentials:
#   alice@example.com  / password123   (500 credits, newsletter subscriber)
#   bob@example.com    / password123   (200 credits)
#   carol@example.com  / password123   (50 credits)
#   dave@example.com   / password123   (0 credits — good for testing insufficient funds)

puts "Seeding..."

# ── Users ─────────────────────────────────────────────────────────────────────

alice = User.find_or_initialize_by(email: "alice@example.com")
alice.assign_attributes(
  name:               "Alice Smith",
  password:           "password123",
  newsletter_opt_in:  true,
  credits:            500
)
alice.save!
puts "  User: #{alice.email} (#{alice.credits} credits)"

bob = User.find_or_initialize_by(email: "bob@example.com")
bob.assign_attributes(
  name:              "Bob Jones",
  password:          "password123",
  newsletter_opt_in: false,
  credits:           200
)
bob.save!
puts "  User: #{bob.email} (#{bob.credits} credits)"

carol = User.find_or_initialize_by(email: "carol@example.com")
carol.assign_attributes(
  name:              "Carol White",
  password:          "password123",
  newsletter_opt_in: true,
  credits:           50
)
carol.save!
puts "  User: #{carol.email} (#{carol.credits} credits)"

dave = User.find_or_initialize_by(email: "dave@example.com")
dave.assign_attributes(
  name:              "Dave Brown",
  password:          "password123",
  newsletter_opt_in: false,
  credits:           0
)
dave.save!
puts "  User: #{dave.email} (#{dave.credits} credits — good for testing insufficient funds)"

# ── Articles ──────────────────────────────────────────────────────────────────

articles_data = [
  {
    user:         alice,
    title:        "Getting Started with EasyOp",
    body:         "EasyOp wraps business logic in composable operations. Every operation includes `Easyop::Operation`, defines a `call` method, and returns a `ctx` object. The `ctx` is both the input bag and the result — check `ctx.success?` or `ctx.failure?` after calling.\n\nOperations are easy to test in isolation, compose into flows, and extend with hooks, schemas, and plugins.",
    published:    true,
    published_at: 3.days.ago
  },
  {
    user:         alice,
    title:        "Using Flows to Compose Operations",
    body:         "Flows let you chain multiple operations that share one `ctx`. If any step calls `ctx.fail!`, the chain halts and rollback runs in reverse order.\n\nUse `skip_if` to make steps optional, and lambda guards for one-off inline conditions. Nested flows work too — a Flow can be a step inside another Flow.",
    published:    true,
    published_at: 2.days.ago
  },
  {
    user:         alice,
    title:        "EasyOp Plugins: Instrumentation, Recording, Async, Transactional",
    body:         "EasyOp ships with four opt-in plugins:\n\n**Instrumentation** fires `ActiveSupport::Notifications` events after every call — hook in your APM or structured logger.\n\n**Recording** persists every execution to an `OperationLog` AR model — great for audit trails and debugging in production.\n\n**Async** adds `.call_async` to any operation, serialising attrs and re-fetching AR objects in the background job.\n\n**Transactional** wraps the full `prepare { call }` chain in an AR transaction — opt out with `transactional false`.",
    published:    true,
    published_at: 1.day.ago
  },
  {
    user:         bob,
    title:        "Understanding ctx.fail! and Rollback",
    body:         "When `ctx.fail!` is called inside a flow step, a `Ctx::Failure` exception propagates up through the flow and triggers `ctx.rollback!`. Each completed step's `rollback` method is called in reverse order.\n\nThis makes flows safe for multi-step database operations — if step 3 fails, steps 2 and 1 can undo their side effects.",
    published:    true,
    published_at: 12.hours.ago
  },
  {
    user:         bob,
    title:        "Draft: Rescue Handlers in Operations",
    body:         "Use `rescue_from ExceptionClass do |e| ... end` to handle exceptions without polluting `call` with begin/rescue blocks. Multiple handlers, inheritance, and the `with: :method_name` shorthand are all supported.",
    published:    false
  },
  {
    user:         carol,
    title:        "Pattern Matching with EasyOp Results",
    body:         "Because `Easyop::Ctx` implements `deconstruct_keys`, you can use Ruby 3+ pattern matching directly on the result:\n\n```ruby\ncase CreateUser.call(params)\nin { success: true, user: }\n  redirect_to profile_path(user)\nin { success: false, errors: Hash => errs }\n  render :new, locals: { errors: errs }\nend\n```",
    published:    true,
    published_at: 6.hours.ago
  },
  {
    user:         carol,
    title:        "Draft: Testing Operations in Isolation",
    body:         "Operations are plain Ruby objects — no Rails magic. Test them with any test framework. Anonymous `Class.new { include Easyop::Operation }` lets you write focused unit tests without touching your real operation classes.",
    published:    false
  }
]

articles_data.each do |attrs|
  Article.find_or_create_by!(title: attrs[:title], user: attrs[:user]) do |a|
    a.body         = attrs[:body]
    a.published    = attrs[:published]
    a.published_at = attrs[:published_at]
  end
end
puts "  Articles: #{Article.count} total (#{Article.published.count} published, #{Article.drafts.count} drafts)"

# ── Newsletter Subscriptions ───────────────────────────────────────────────────

subscriptions = [
  { email: "alice@example.com",    name: "Alice Smith", confirmed: true },
  { email: "carol@example.com",    name: "Carol White", confirmed: true },
  { email: "reader1@example.com",  name: "Reader One",  confirmed: true },
  { email: "reader2@example.com",  name: "Reader Two",  confirmed: true },
  { email: "reader3@example.com",  name: "Reader Three", confirmed: true },
  { email: "pending@example.com",  name: "Pending User", confirmed: false },
  { email: "unsubbed@example.com", name: "Ex-Reader",    confirmed: true,
    unsubscribed_at: 1.week.ago }
]

subscriptions.each do |attrs|
  Subscription.find_or_create_by!(email: attrs[:email]) do |s|
    s.name             = attrs[:name]
    s.confirmed        = attrs[:confirmed]
    s.unsubscribed_at  = attrs[:unsubscribed_at]
  end
end
puts "  Subscriptions: #{Subscription.count} total (#{Subscription.confirmed.where(unsubscribed_at: nil).count} active confirmed)"

# ── Broadcasts ────────────────────────────────────────────────────────────────

first_article = Article.published.first
if first_article && Broadcast.none?
  Broadcast.create!(
    subject:    "Welcome to the EasyOp Blog!",
    body:       "We just published our first article. Check out \"#{first_article.title}\".",
    article_id: first_article.id,
    sent_at:    2.days.ago
  )
  puts "  Broadcast: 1 past broadcast created"
end

# ── Operation Logs (sample history) ───────────────────────────────────────────

if OperationLog.count < 5
  [
    { operation_name: "Users::Register",       success: true,  duration_ms: 8.4,  performed_at: 3.days.ago },
    { operation_name: "Users::Authenticate",   success: true,  duration_ms: 2.1,  performed_at: 2.days.ago },
    { operation_name: "Articles::Create",      success: true,  duration_ms: 5.7,  performed_at: 2.days.ago },
    { operation_name: "Articles::Publish",     success: true,  duration_ms: 3.2,  performed_at: 1.day.ago },
    { operation_name: "Users::Authenticate",   success: false, duration_ms: 1.8,
      error_message: "Invalid email or password",              performed_at: 12.hours.ago },
    { operation_name: "Newsletter::Subscribe", success: true,  duration_ms: 4.1,  performed_at: 6.hours.ago },
    { operation_name: "Articles::Create",      success: false, duration_ms: 2.9,
      error_message: "Could not save article",                 performed_at: 2.hours.ago }
  ].each do |attrs|
    OperationLog.create!(attrs)
  end
  puts "  OperationLogs: #{OperationLog.count} sample entries"
end

# ── Sample Purchases (demonstrate encrypt_params) ────────────────────────────

if Payment.count < 2
  # Run real operations so OperationLog gets populated with encrypted params_data
  alice_purchase = Flows::PurchaseAccess.call(
    user:               alice,
    amount_cents:       999,
    credit_card_number: "4242424242424242",
    cvv:                "123",
    billing_zip:        "10001",
    tier:               "standard"
  )
  if alice_purchase.success?
    puts "  Purchase: alice bought standard access (payment ##{alice_purchase.payment.transaction_id})"
  end

  bob_purchase = Flows::PurchaseAccess.call(
    user:               bob,
    amount_cents:       2999,
    credit_card_number: "5555555555554444",
    cvv:                "456",
    billing_zip:        "90210",
    tier:               "premium"
  )
  if bob_purchase.success?
    puts "  Purchase: bob bought premium access (payment ##{bob_purchase.payment.transaction_id})"
  end

  puts "  Payments: #{Payment.count} total. Check Op Logs to see encrypted params."
end

# ── Summary ────────────────────────────────────────────────────────────────────

puts ""
puts "Done! Test accounts:"
puts "  alice@example.com  / password123  (500 credits, newsletter opt-in)"
puts "  bob@example.com    / password123  (200 credits)"
puts "  carol@example.com  / password123  (50 credits)"
puts "  dave@example.com   / password123  (0 credits)"
puts ""
puts "Transfer credits between accounts to test Flows::TransferCredits."
puts "Dave has 0 credits — use him to test the 'Insufficient credits' error."
