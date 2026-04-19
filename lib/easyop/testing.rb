# frozen_string_literal: true

module Easyop
  # Test helpers for EasyOp operations, flows, and plugins.
  #
  # Include in Minitest or RSpec:
  #
  #   class MyTest < Minitest::Test
  #     include Easyop::Testing
  #   end
  #
  #   RSpec.describe MyOp do
  #     include Easyop::Testing
  #   end
  #
  # Provides:
  #   - op_call / op_call! / stub_op
  #   - assert_op_success / assert_op_failure / assert_ctx_has
  #   - Easyop::Testing::FakeModel   — spy AR model for Recording plugin
  #   - assert_params_recorded / assert_params_filtered / assert_params_encrypted
  #   - assert_result_recorded / assert_ar_ref_in_params / assert_ar_ref_in_result
  #   - decrypt_recorded_param / with_recording_secret
  #   - capture_async / perform_async_inline
  #   - assert_async_enqueued / assert_async_queue / assert_async_wait / assert_no_async_enqueued
  #   - capture_events / assert_event_emitted / assert_event_payload / assert_no_events
  module Testing
    autoload :Assertions,           "easyop/testing/assertions"
    autoload :FakeModel,            "easyop/testing/fake_model"
    autoload :RecordingAssertions,  "easyop/testing/recording_assertions"
    autoload :AsyncAssertions,      "easyop/testing/async_assertions"
    autoload :EventAssertions,      "easyop/testing/event_assertions"

    def self.included(base)
      base.include Easyop::Testing::Assertions
      base.include Easyop::Testing::RecordingAssertions
      base.include Easyop::Testing::AsyncAssertions
      base.include Easyop::Testing::EventAssertions
    end
  end
end
