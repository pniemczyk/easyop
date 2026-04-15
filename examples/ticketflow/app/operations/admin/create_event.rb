module Admin
  class CreateEvent < ApplicationOperation
    params do
      required :title, String
      required :starts_at, String
    end

    # params_data (automatic): records only INPUT keys — title, starts_at, and
    #   any other keys passed at call time. The ctx.event created during #call
    #   is NOT in params_data; it belongs in result_data.
    #
    # result_data: full ctx snapshot after the call — includes the newly created
    #   Event object (serialized as {id:, class:}) for audit/debugging.
    record_result true

    def call
      ctx.event = Event.create!(
        title: ctx.title,
        description: ctx.description,
        venue: ctx.venue,
        location: ctx.location,
        starts_at: ctx.starts_at,
        ends_at: ctx.ends_at,
        cover_color: ctx.cover_color || "#6366f1"
      )
    end
  end
end
