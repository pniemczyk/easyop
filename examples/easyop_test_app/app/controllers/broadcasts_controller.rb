# Demonstrates: prepare.on_success { }.on_failure { } with blocks (on Operation, not Flow)
# Also demonstrates the PublishAndBroadcast flow and Newsletter::SendBroadcast.call_async
class BroadcastsController < ApplicationController
  before_action :require_login
  before_action :set_article

  def new
    @broadcast = Broadcast.new
  end

  def create
    if params[:async].present?
      # Demonstrates Async plugin — enqueues the broadcast as a background job
      Newsletter::SendBroadcast.call_async(
        subject:    params[:subject] || @article.title,
        body:       @article.body,
        article_id: @article.id
      )
      redirect_to article_path(@article), notice: "Broadcast queued! Subscribers will receive it shortly."
    else
      # Demonstrates FlowBuilder prepare + on_success/on_failure blocks
      Flows::PublishAndBroadcast.prepare
        .on_success { |ctx| redirect_to article_path(ctx.article), notice: "Published and sent to #{ctx.recipients_count} subscribers!" }
        .on_failure { |ctx| redirect_to article_path(@article), alert: ctx.error }
        .call(article: @article, subject: params[:subject] || broadcast_params[:subject] || @article.title, body: @article.body)
    end
  end

  private

  def set_article
    @article = current_user.articles.find(params[:article_id])
  rescue ActiveRecord::RecordNotFound
    redirect_to articles_path, alert: "Article not found."
  end

  def broadcast_params
    params.require(:broadcast).permit(:subject)
  end
end
