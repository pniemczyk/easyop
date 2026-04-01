# TicketFlow demo seed data

puts "Seeding TicketFlow demo data..."

# ── Users ─────────────────────────────────────────────────────────────────────

admin = User.find_or_create_by!(email: "admin@ticketflow.com") do |u|
  u.name = "Admin User"
  u.password = "password123"
  u.password_confirmation = "password123"
  u.admin = true
end
puts "Admin: admin@ticketflow.com / password123"

regular_user = User.find_or_create_by!(email: "user@ticketflow.com") do |u|
  u.name = "Jane Smith"
  u.password = "password123"
  u.password_confirmation = "password123"
  u.admin = false
end
puts "User:  user@ticketflow.com / password123"

# ── Discount codes ────────────────────────────────────────────────────────────

save10 = DiscountCode.find_or_create_by!(code: "SAVE10") do |d|
  d.discount_type = "percentage"
  d.amount = 10
  d.active = true
end

flat20 = DiscountCode.find_or_create_by!(code: "FLAT20") do |d|
  d.discount_type = "fixed"
  d.amount = 2000  # $20 in cents
  d.max_uses = 50
  d.active = true
end

vip50 = DiscountCode.find_or_create_by!(code: "VIP50") do |d|
  d.discount_type = "percentage"
  d.amount = 50
  d.max_uses = 10
  d.active = true
end

puts "Discount codes: SAVE10, FLAT20, VIP50"

# ── Events ────────────────────────────────────────────────────────────────────

# Event 1: Upcoming — published
event1 = Event.find_or_create_by!(title: "Neon Horizons Music Festival") do |e|
  e.description = "Three days of incredible electronic and indie music at San Francisco's iconic waterfront venue. Featuring 50+ artists across 5 stages, gourmet food vendors, and stunning bay views.\n\nLineup includes top-tier DJs, emerging indie bands, and surprise guests. This is the must-attend festival of the summer."
  e.venue = "Chase Center"
  e.location = "San Francisco, CA"
  e.starts_at = 6.weeks.from_now.beginning_of_day + 18.hours
  e.ends_at = 6.weeks.from_now.beginning_of_day + 23.hours
  e.published = true
  e.cover_color = "#6366f1"
end

event1.ticket_types.find_or_create_by!(name: "General Admission") do |tt|
  tt.description = "Access to all outdoor stages and general areas"
  tt.price_cents = 7900  # $79
  tt.quantity = 500
end

event1.ticket_types.find_or_create_by!(name: "VIP Experience") do |tt|
  tt.description = "Dedicated viewing areas, complimentary drinks, and artist lounge access"
  tt.price_cents = 24900  # $249
  tt.quantity = 100
end

event1.ticket_types.find_or_create_by!(name: "Early Bird") do |tt|
  tt.description = "Limited early bird pricing — first come, first served"
  tt.price_cents = 4900  # $49
  tt.quantity = 50
  tt.sold_count = 48  # almost gone!
end

# Event 2: Upcoming — published
event2 = Event.find_or_create_by!(title: "Rails & Ruby Conference 2026") do |e|
  e.description = "The premier Ruby on Rails conference brings together developers from around the world for two days of talks, workshops, and networking.\n\nThis year's theme: 'The Future of Full-Stack Ruby'. Hear from core contributors, senior engineers at top companies, and passionate open-source maintainers."
  e.venue = "Moscone Center"
  e.location = "San Francisco, CA"
  e.starts_at = 8.weeks.from_now.beginning_of_day + 9.hours
  e.ends_at = 8.weeks.from_now.beginning_of_day + 19.hours
  e.published = true
  e.cover_color = "#dc2626"
end

event2.ticket_types.find_or_create_by!(name: "Conference Pass") do |tt|
  tt.description = "Full 2-day conference access including all talks and workshops"
  tt.price_cents = 59900  # $599
  tt.quantity = 300
end

event2.ticket_types.find_or_create_by!(name: "Workshop Day Only") do |tt|
  tt.description = "Hands-on workshop day — pre-registration required for specific workshops"
  tt.price_cents = 19900  # $199
  tt.quantity = 80
end

event2.ticket_types.find_or_create_by!(name: "Student/Indie") do |tt|
  tt.description = "Discounted pass for students and independent developers (ID required)"
  tt.price_cents = 29900  # $299
  tt.quantity = 50
end

# Event 3: Upcoming — published
event3 = Event.find_or_create_by!(title: "Design Systems Summit") do |e|
  e.description = "A one-day deep-dive into design systems, UI/UX, and the intersection of design and engineering. Perfect for designers, frontend developers, and product managers."
  e.venue = "SFJAZZ Center"
  e.location = "San Francisco, CA"
  e.starts_at = 12.weeks.from_now.beginning_of_day + 9.hours
  e.ends_at = 12.weeks.from_now.beginning_of_day + 18.hours
  e.published = true
  e.cover_color = "#0ea5e9"
end

event3.ticket_types.find_or_create_by!(name: "Full Day Pass") do |tt|
  tt.description = "Full access to all sessions, panels, and networking lunch"
  tt.price_cents = 14900  # $149
  tt.quantity = 200
end

event3.ticket_types.find_or_create_by!(name: "Team Pack (5 passes)") do |tt|
  tt.description = "Bring your team — 5 passes at a group discount"
  tt.price_cents = 59900  # $599 for 5
  tt.quantity = 20
end

# Event 4: Past (not shown publicly)
event4 = Event.find_or_create_by!(title: "Winter Gala 2025") do |e|
  e.description = "A magical evening of performances, art installations, and fine dining."
  e.venue = "The Palace Hotel"
  e.location = "San Francisco, CA"
  e.starts_at = 3.months.ago
  e.ends_at = 3.months.ago + 4.hours
  e.published = true
  e.cover_color = "#8b5cf6"
end

event4.ticket_types.find_or_create_by!(name: "Standard") do |tt|
  tt.price_cents = 9900
  tt.quantity = 150
  tt.sold_count = 87
end

# Event 5: Draft (unpublished)
event5 = Event.find_or_create_by!(title: "Autumn Hackathon 2026") do |e|
  e.description = "48-hour hackathon with $50,000 in prizes. Build something amazing."
  e.venue = "TBD"
  e.location = "San Francisco, CA"
  e.starts_at = 20.weeks.from_now
  e.published = false
  e.cover_color = "#f59e0b"
end

puts "Created 5 events (3 upcoming published, 1 past, 1 draft)"

# ── Sample paid orders ────────────────────────────────────────────────────────

def create_sample_order(event:, ticket_type:, quantity:, name:, email:, user: nil, coupon: nil)
  return if Order.exists?(email: email, event: event)

  subtotal = ticket_type.price_cents * quantity
  discount = coupon ? coupon.calculate_discount(subtotal) : 0
  total = [subtotal - discount, 0].max

  order = Order.create!(
    event: event,
    user: user,
    email: email,
    name: name,
    status: "paid",
    subtotal_cents: subtotal,
    discount_cents: discount,
    total_cents: total,
    discount_code: coupon,
    payment_reference: "PAY-#{SecureRandom.hex(8).upcase}",
    paid_at: rand(1..30).days.ago
  )

  order.order_items.create!(
    ticket_type: ticket_type,
    quantity: quantity,
    unit_price_cents: ticket_type.price_cents
  )

  quantity.times do
    order.tickets.create!(
      ticket_type: ticket_type,
      attendee_name: name,
      attendee_email: email,
      status: "active",
      delivered_at: order.paid_at + 5.seconds
    )
  end

  ticket_type.increment!(:sold_count, quantity)
  coupon&.increment!(:use_count)

  order
end

# Event 1 orders
ga = event1.ticket_types.find_by(name: "General Admission")
vip = event1.ticket_types.find_by(name: "VIP Experience")

create_sample_order(event: event1, ticket_type: ga, quantity: 2, name: "Alex Johnson", email: "alex@example.com", user: regular_user)
create_sample_order(event: event1, ticket_type: vip, quantity: 1, name: "Sarah Chen", email: "sarah@example.com", coupon: save10)
create_sample_order(event: event1, ticket_type: ga, quantity: 3, name: "Marcus Webb", email: "marcus@example.com")
create_sample_order(event: event1, ticket_type: vip, quantity: 2, name: "Emily Rodriguez", email: "emily@example.com", coupon: flat20)
create_sample_order(event: event1, ticket_type: ga, quantity: 1, name: "David Kim", email: "david@example.com")
create_sample_order(event: event1, ticket_type: ga, quantity: 4, name: "Lisa Park", email: "lisa@example.com", coupon: save10)

# Event 2 orders
conf = event2.ticket_types.find_by(name: "Conference Pass")
workshop = event2.ticket_types.find_by(name: "Workshop Day Only")

create_sample_order(event: event2, ticket_type: conf, quantity: 1, name: "Tom Wilson", email: "tom@startup.io")
create_sample_order(event: event2, ticket_type: conf, quantity: 2, name: "Rachel Lee", email: "rachel@bigcorp.com")
create_sample_order(event: event2, ticket_type: workshop, quantity: 1, name: "Jordan Brown", email: "jordan@freelance.dev", coupon: save10)
create_sample_order(event: event2, ticket_type: conf, quantity: 1, name: "Priya Patel", email: "priya@tech.co")

# Event 3 orders
day_pass = event3.ticket_types.find_by(name: "Full Day Pass")
create_sample_order(event: event3, ticket_type: day_pass, quantity: 1, name: "Chris Martinez", email: "chris@design.co")
create_sample_order(event: event3, ticket_type: day_pass, quantity: 2, name: "Sam Taylor", email: "sam@ux.studio")

# Past event orders
std = event4.ticket_types.find_by(name: "Standard")
create_sample_order(event: event4, ticket_type: std, quantity: 2, name: "Nina Anderson", email: "nina@email.com")
create_sample_order(event: event4, ticket_type: std, quantity: 1, name: "Kevin Liu", email: "kevin@example.com")

puts "Created sample orders with tickets"
puts "\nSeed complete! App ready to demo."
puts "  Admin: admin@ticketflow.com / password123"
puts "  User:  user@ticketflow.com  / password123"
