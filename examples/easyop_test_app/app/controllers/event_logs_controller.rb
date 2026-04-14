class EventLogsController < ApplicationController
  before_action :require_login

  def index
    @event_logs = EventLog.recent
    @event_logs = @event_logs.for_event(params[:event_name]) if params[:event_name].present?
    @event_logs = @event_logs.limit(200)
    @event_name_filter = params[:event_name].presence
    @event_names = EventLog.distinct.order(:event_name).pluck(:event_name)
  end
end
