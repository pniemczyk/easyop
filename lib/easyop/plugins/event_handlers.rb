# frozen_string_literal: true

module Easyop
  module Plugins
    # Subscribes an operation class to handle domain events.
    #
    # The handler operation receives the event payload merged into ctx, plus
    # ctx.event (the Easyop::Events::Event object itself for sync dispatch).
    #
    # Basic usage:
    #
    #   class SendOrderConfirmation < ApplicationOperation
    #     plugin Easyop::Plugins::EventHandlers
    #
    #     on "order.placed"
    #
    #     def call
    #       event    = ctx.event        # Easyop::Events::Event
    #       order_id = ctx.order_id     # payload keys merged into ctx
    #       OrderMailer.confirm(order_id).deliver_later
    #     end
    #   end
    #
    # Async dispatch (requires Easyop::Plugins::Async also installed):
    #
    #   class IndexOrder < ApplicationOperation
    #     plugin Easyop::Plugins::Async, queue: "indexing"
    #     plugin Easyop::Plugins::EventHandlers
    #
    #     on "order.*",      async: true
    #     on "inventory.**", async: true, queue: "low"
    #
    #     def call
    #       # For async dispatch ctx.event_data is a Hash (serialized for ActiveJob).
    #       # Reconstruct if needed: Easyop::Events::Event.new(**ctx.event_data)
    #       SearchIndex.reindex(ctx.order_id)
    #     end
    #   end
    #
    # Wildcard patterns:
    #   "order.*"     — matches order.placed, order.shipped (not order.payment.failed)
    #   "warehouse.**" — matches warehouse.stock.updated, warehouse.zone.moved, etc.
    module EventHandlers
      def self.install(base, **_options)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Subscribe this operation to events matching +pattern+.
        #
        # Registration happens at class-load time and is bound to the bus that is
        # active when the class is evaluated. Configure the bus before loading
        # handler classes (e.g. in a Rails initializer that runs before autoloading).
        #
        # @param pattern [String, Regexp]  event name or glob
        # @param async   [Boolean]         enqueue via call_async (requires Async plugin)
        # @param options [Hash]            e.g. queue: "low" (overrides Async default)
        def on(pattern, async: false, **options)
          _event_handler_registrations << { pattern: pattern, async: async, options: options }

          Easyop::Events::Registry.register_handler(
            pattern:       pattern,
            handler_class: self,
            async:         async,
            **options
          )
        end

        # @api private — list of registrations declared on this class
        def _event_handler_registrations
          @_event_handler_registrations ||= []
        end
      end
    end
  end
end
