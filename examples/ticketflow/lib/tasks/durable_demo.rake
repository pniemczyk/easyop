# frozen_string_literal: true

namespace :easyop do
  desc <<~DESC
    Run a durable Mode-3 FulfillOrder demo against a paid order.

    Picks the first paid order from the database, calls Flows::FulfillOrder,
    then advances the scheduler (collapsing wait: windows) until the FlowRun
    reaches a terminal state.

    Usage:
      bin/rails easyop:fulfill_demo

    Prerequisites:
      bin/rails db:migrate            # creates easy_flow_runs / easy_scheduled_tasks tables
      bin/rails db:seed               # creates sample events, orders, tickets
  DESC
  task fulfill_demo: :environment do
    require 'active_support/testing/time_helpers'
    extend ActiveSupport::Testing::TimeHelpers

    order = Order.paid.first
    unless order
      abort <<~MSG

        No paid orders found. Seed the database first:

          bin/rails db:seed

        Then complete a checkout at http://localhost:3000 or run:

          bin/rails easyop:fulfill_demo

      MSG
    end

    puts
    puts "  ── Durable FulfillOrder demo ──────────────────────────────────"
    puts "  Order ##{order.id}  status=#{order.status}  event=#{order.event.title}"
    puts

    puts "  Calling Flows::FulfillOrder.call(order: order) ..."
    flow_run = Flows::FulfillOrder.call(order: order)
    puts "  FlowRun ##{flow_run.id}  status=#{flow_run.status}"
    puts "  (Flow 3 — immediately ran SendOrderConfirmation.async, now waiting)"
    puts

    puts "  Advancing scheduler to drain all async steps ..."
    origin = Time.current
    5.times do |i|
      break if flow_run.terminal?

      pending_count = EasyScheduledTask.where(state: 'scheduled').count
      break if pending_count.zero?

      # Each tick jumps further from origin so that tasks scheduled during a
      # previous tick (which used traveled time for their run_at) are covered.
      advance_secs = (i + 1) * 55.hours.to_i
      puts "  [tick #{i + 1}]  traveling +#{(i + 1) * 55}h from origin, ticking scheduler ..."
      travel_to(origin + advance_secs) do
        Easyop::Scheduler.tick_now!
      end
      flow_run.reload
      puts "           FlowRun status=#{flow_run.status}"
    end

    puts
    puts "  ── Result ────────────────────────────────────────────────────"
    puts "  FlowRun ##{flow_run.id}  status=#{flow_run.status}"

    steps = EasyFlowRunStep.where(flow_run_id: flow_run.id).order(:step_index)
    if steps.any?
      puts "  Steps:"
      steps.each do |s|
        duration = s.finished_at && s.started_at ? " (#{((s.finished_at - s.started_at) * 1000).round}ms)" : ''
        puts "    #{s.step_index}. #{s.operation_class.split('::').last.ljust(30)} #{s.status}#{duration}"
      end
    end

    puts
    if flow_run.succeeded?
      puts "  ✓ FulfillOrder durable flow completed successfully"
    else
      puts "  ✗ FlowRun ended with status=#{flow_run.status}"
    end
    puts
  end
end
