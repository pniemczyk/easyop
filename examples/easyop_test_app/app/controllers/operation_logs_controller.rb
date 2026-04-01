class OperationLogsController < ApplicationController
  before_action :require_login

  def index
    @logs = OperationLog.recent.limit(100)
  end
end
