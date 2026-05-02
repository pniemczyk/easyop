# frozen_string_literal: true

require_relative 'scheduler/serializer'
require_relative 'persistent_flow/flow_run_model'
require_relative 'persistent_flow/flow_run_step_model'
require_relative 'persistent_flow/runner'
require_relative 'persistent_flow/perform_step_job'

module Easyop
  # Deprecated. Use `include Easyop::Flow` + `subject :foo` instead.
  #
  # `Easyop::PersistentFlow` is now a thin backward-compatibility shim.
  # Including it is equivalent to `include Easyop::Flow`.
  # It will be removed in v0.6.
  module PersistentFlow
    def self.included(base)
      warn '[easyop] Easyop::PersistentFlow is deprecated; use Easyop::Flow instead.' if $VERBOSE
      base.include(Easyop::Flow)
      # Force durable mode regardless of subject — backward compat for existing PersistentFlow users.
      base.instance_variable_set(:@_persistent_flow_compat, true)
    end
  end
end
