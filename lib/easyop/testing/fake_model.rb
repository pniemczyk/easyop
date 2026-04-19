# frozen_string_literal: true

require "json"

module Easyop
  module Testing
    # Lightweight AR-compatible spy for Easyop::Plugins::Recording.
    # Pass an instance as the `model:` option to record into memory instead of a DB.
    #
    #   model = Easyop::Testing::FakeModel.new
    #
    #   op = Class.new do
    #     include Easyop::Operation
    #     plugin Easyop::Plugins::Recording, model: model
    #     def self.name = "My::Op"
    #     def call; ctx.out = 42; end
    #   end
    #
    #   op.call(name: "alice")
    #   model.last_params  #=> { "name" => "alice" }
    class FakeModel
      STANDARD_COLUMNS = %w[
        operation_name success error_message params_data result_data
        duration_ms performed_at root_reference_id reference_id
        parent_operation_name parent_reference_id execution_index
      ].freeze

      attr_reader :records

      # @param extra_columns [Array<String, Symbol>]
      def initialize(extra_columns: [])
        @records = []
        @columns = STANDARD_COLUMNS + extra_columns.map(&:to_s)
      end

      # AR interface required by the Recording plugin
      def column_names = @columns

      def create!(attrs)
        record = attrs.transform_keys(&:to_sym)
        @records << record
        record
      end

      def count      = @records.size
      def any?       = @records.any?
      def empty?     = @records.empty?
      def last       = @records.last
      def first      = @records.first
      def all        = @records.dup
      def clear!     = @records.clear && self

      # Parsed params_data of the last record. Returns {} when nothing recorded.
      def last_params  = parse_json(last&.fetch(:params_data, nil))

      # Parsed result_data of the last record. Returns {} when nothing recorded.
      def last_result  = parse_json(last&.fetch(:result_data, nil))

      # Parsed params for record at index +i+.
      def params_at(i)  = parse_json(@records[i]&.fetch(:params_data, nil))

      # Parsed result for record at index +i+.
      def result_at(i)  = parse_json(@records[i]&.fetch(:result_data, nil))

      # All records whose operation_name matches.
      def records_for(name) = @records.select { |r| r[:operation_name] == name.to_s }

      private

      def parse_json(raw)
        return {} if raw.nil? || raw == ""
        JSON.parse(raw)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
