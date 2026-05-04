module Flows
  # Durable onboarding drip for a newly registered user.
  #
  # Mode 3 (durable): `subject :user` makes .call return an EasyFlowRun
  # instead of Ctx. Each async step suspends the flow and schedules a
  # EasyScheduledTask; the Scheduler resumes it when `run_at` arrives.
  #
  # Contrast with Flows::PublishAndBroadcast (Mode 2 — no subject):
  #   - PublishAndBroadcast fires Newsletter::SendBroadcast.async immediately
  #     and returns Ctx. No wait, no resume.
  #   - OnboardUser chains three async steps across time: immediate →
  #     1.day → 7.days. Each step resumes from the persisted ctx.
  #
  # Run locally in development:
  #   flow_run = Flows::OnboardUser.call(user: User.first)
  #   flow_run.class          # => EasyFlowRun
  #   flow_run.status         # => "running" (waiting for day-1 step)
  #
  #   # Advance the scheduler manually (dev/test only):
  #   Easyop::Scheduler.tick_now!
  class OnboardUser < ApplicationOperation
    include Easyop::Flow
    transactional false

    subject :user   # triggers Mode 3 — .call returns EasyFlowRun

    flow Users::SendWelcomeEmail.async,
         Users::SendDay1Tip.async(wait: 1.day),
         Users::SendEngagementCheck.async(wait: 7.days)
  end
end
