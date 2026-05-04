module Tickets
  # Sends a satisfaction survey after the event ends (scheduled via wait: in FulfillOrder).
  # In production: email the survey link. Here: stamps a timestamp.
  class SendPostEventSurvey < ApplicationOperation
    def call
      ctx.survey_sent_at = Time.current
      Rails.logger.info "[SendPostEventSurvey] Survey sent for order ##{ctx.order.id}"
    end
  end
end
