module Admin
  class CreateEvent < ApplicationOperation
    params do
      required :title, String
      required :starts_at, String
    end

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
