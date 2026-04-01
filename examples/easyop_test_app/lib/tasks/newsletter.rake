namespace :newsletter do
  desc "Send a broadcast to all confirmed subscribers (demonstrates .call! with rescue Easyop::Ctx::Failure)"
  task :broadcast, [:subject, :body] => :environment do |_t, args|
    subject = args[:subject] || "Weekly Digest"
    body    = args[:body]    || "Here's what's new this week on EasyOp Blog."

    puts "[newsletter:broadcast] Sending broadcast: #{subject}"

    # Demonstrates .call! — raises Easyop::Ctx::Failure on failure
    # Used in rake tasks / background jobs where you want exception semantics
    begin
      ctx = Newsletter::SendBroadcast.call!(subject: subject, body: body)
      puts "[newsletter:broadcast] Sent to #{ctx.recipients_count} subscriber(s). Broadcast ID: #{ctx.broadcast_id}"
    rescue Easyop::Ctx::Failure => e
      # Graceful failure: log the error and exit with non-zero status
      $stderr.puts "[newsletter:broadcast] FAILED: #{e.ctx.error}"
      exit 1
    end
  end
end
