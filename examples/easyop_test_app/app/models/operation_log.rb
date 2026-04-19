class OperationLog < ApplicationRecord
  validates :operation_name, :performed_at, presence: true
  validates :success, inclusion: { in: [true, false] }

  scope :successes,       -> { where(success: true) }
  scope :failures,        -> { where(success: false) }
  scope :for_operation,   ->(name) { where(operation_name: name) }
  scope :roots,           -> { where(parent_reference_id: nil) }
  scope :recent,          -> { order(performed_at: :desc) }
  scope :for_tree,        ->(id) { where(root_reference_id: id).order(Arel.sql("COALESCE(execution_index, 0) ASC, performed_at ASC")) }
  scope :with_params,     -> { where.not(params_data: [nil, ""]) }
  scope :with_result,     -> { where.not(result_data: [nil, ""]) }
  scope :encrypted,       -> { where("params_data LIKE ?", '%$easyop_encrypted%') }

  def root?
    parent_reference_id.nil?
  end

  def parsed_params
    @parsed_params ||= params_data ? JSON.parse(params_data) : {}
  rescue JSON::ParserError
    {}
  end

  def parsed_result
    @parsed_result ||= result_data ? JSON.parse(result_data) : {}
  rescue JSON::ParserError
    {}
  end

  def fully_successful_tree?
    OperationLog.for_tree(root_reference_id || reference_id).all?(&:success?)
  end

  def encrypted_params_keys
    parsed_params.select { |_, v| encrypted_marker?(v) }.keys
  end

  def has_encrypted_params?
    parsed_params.any? { |_, v| encrypted_marker?(v) }
  end

  private

  def encrypted_marker?(value)
    value.is_a?(Hash) && (value.key?("$easyop_encrypted") || value.key?(:$easyop_encrypted))
  end
end
