# frozen_string_literal: true

require 'json'

module Easyop
  module Scheduler
    # Serialize / deserialize operation attrs across async boundaries.
    #
    # Primitives (String, Integer, Float, Boolean, nil, Array, Hash) serialize
    # to JSON unchanged. ActiveRecord objects serialize as a pointer:
    #   { "__ar_class" => "User", "__ar_id" => 42 }
    # and are re-fetched fresh from the database on deserialization.
    module Serializer
      def self.serialize(attrs)
        JSON.dump(
          attrs.each_with_object({}) do |(k, v), h|
            h[k.to_s] = _serialize_value(v)
          end
        )
      end

      def self.deserialize(json)
        raw = JSON.parse(json)
        raw.each_with_object({}) do |(k, v), h|
          h[k.to_sym] = _deserialize_value(v)
        end
      end

      def self._serialize_value(v)
        if defined?(ActiveRecord::Base) && v.is_a?(ActiveRecord::Base)
          { '__ar_class' => v.class.name, '__ar_id' => v.id }
        elsif v.is_a?(Array)
          v.map { |item| _serialize_value(item) }
        elsif v.is_a?(Hash)
          v.each_with_object({}) { |(hk, hv), h| h[hk.to_s] = _serialize_value(hv) }
        else
          v
        end
      end
      private_class_method :_serialize_value

      def self._deserialize_value(v)
        if v.is_a?(Hash) && v['__ar_class'] && v['__ar_id']
          v['__ar_class'].constantize.find(v['__ar_id'])
        elsif v.is_a?(Array)
          v.map { |item| _deserialize_value(item) }
        elsif v.is_a?(Hash)
          v.each_with_object({}) { |(hk, hv), h| h[hk.to_sym] = _deserialize_value(hv) }
        else
          v
        end
      end
      private_class_method :_deserialize_value
    end
  end
end
