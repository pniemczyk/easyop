# frozen_string_literal: true

namespace :easyop do
  desc <<~DESC
    Demonstrate async_retry + blocking: true in Flows::FulfillOrder.

    Runs two scenarios against the first paid order in the database:

      Scenario A — SendOrderConfirmation fails all 3 retries
        → FlowRun status: failed
        → SendEventReminder + SendPostEventSurvey: skipped

      Scenario B — SendOrderConfirmation fails twice, succeeds on 3rd attempt
        → FlowRun status: succeeded
        → All three steps completed

    Usage:
      bin/rails easyop:blocking_retry_demo

    Prerequisites:
      bin/rails db:seed   # creates sample events and paid orders
  DESC
  task blocking_retry_demo: :environment do
    require 'active_support/testing/time_helpers'
    extend ActiveSupport::Testing::TimeHelpers

    order = Order.paid.first
    unless order
      abort "\nNo paid orders found. Run `bin/rails db:seed` first.\n"
    end

    separator = '─' * 62

    def print_steps(flow_run)
      steps = EasyFlowRunStep.where(flow_run_id: flow_run.id).order(:step_index, :created_at)
      if steps.any?
        steps.each do |s|
          label = s.operation_class.split('::').last.ljust(28)
          extra = s.error_message.present? ? "  → #{s.error_message.truncate(50)}" : ''
          puts "    #{s.step_index}  #{label}  #{s.status.upcase}#{extra}"
        end
      else
        puts '    (no step records yet)'
      end
    end

    def drain_flow(flow_run, origin)
      5.times do |i|
        break if flow_run.terminal?
        break if EasyScheduledTask.where(state: 'scheduled').none?

        advance_secs = (i + 1) * 55.hours.to_i
        travel_to(origin + advance_secs) { Easyop::Scheduler.tick_now! }
        flow_run.reload
      end
    end

    # ── Scenario A: all 3 confirmation attempts fail ──────────────────────────

    puts
    puts "  #{separator}"
    puts "  Scenario A — SendOrderConfirmation fails all 3 retries"
    puts "  #{separator}"
    puts "  Order ##{order.id}  event=#{order.event.title}"
    puts

    Tickets::SendOrderConfirmation.simulate_failures!(99)   # always fail

    origin_a = Time.current
    flow_a   = Flows::FulfillOrder.call(order: order)
    puts "  FlowRun ##{flow_a.id}  status=#{flow_a.status}  (scheduler has first async task)"
    puts

    drain_flow(flow_a, origin_a)

    puts "  Final status: #{flow_a.status.upcase}"
    puts "  Steps:"
    print_steps(flow_a)
    puts

    Tickets::SendOrderConfirmation.reset_simulation!

    # ── Scenario B: fails twice, succeeds on 3rd attempt ─────────────────────

    # Use a fresh order row by reloading (same order, new FlowRun)
    order.reload
    puts "  #{separator}"
    puts "  Scenario B — SendOrderConfirmation fails twice, succeeds on 3rd"
    puts "  #{separator}"
    puts "  Order ##{order.id}  event=#{order.event.title}"
    puts

    Tickets::SendOrderConfirmation.simulate_failures!(2)    # fail twice, then succeed

    origin_b = Time.current
    flow_b   = Flows::FulfillOrder.call(order: order)
    puts "  FlowRun ##{flow_b.id}  status=#{flow_b.status}  (scheduler has first async task)"
    puts

    drain_flow(flow_b, origin_b)

    puts "  Final status: #{flow_b.status.upcase}"
    puts "  Steps:"
    print_steps(flow_b)

    Tickets::SendOrderConfirmation.reset_simulation!

    puts
    puts "  #{separator}"
    puts "  ✓ Demo complete. Check /admin/operation_logs for the full audit trail."
    puts "  #{separator}"
    puts
  end
end
