# Demonstrates:
#   - Pattern matching on ctx result (case ... in { success: true, article: })
#   - .call! with rescue Easyop::Ctx::Failure
class ArticlesController < ApplicationController
  before_action :require_login, except: [:index, :show]
  before_action :set_article, only: [:show, :publish, :destroy]
  before_action :require_article_owner, only: [:publish, :destroy]

  def index
    @articles = Article.published.includes(:user).order(published_at: :desc)
    @drafts   = current_user ? current_user.articles.drafts.order(created_at: :desc) : []
  end

  def show
  end

  def new
    @article = Article.new
  end

  def create
    # Pattern matching on the ctx result — demonstrates all three patterns
    case Articles::Create.call(article_params.merge(user: current_user))
    in { success: true, article: }
      redirect_to article, notice: "Article created!"
    in { success: false, errors: Hash => errs } if errs.any?
      @errors = errs
      @article = Article.new(article_params.except(:user))
      render :new, status: :unprocessable_entity
    in { success: false, error: String => msg }
      flash[:alert] = msg
      @article = Article.new(article_params.except(:user))
      render :new, status: :unprocessable_entity
    end
  end

  def publish
    # Demonstrates .call! — raises Easyop::Ctx::Failure on operation failure
    ctx = Articles::Publish.call!(article: @article)
    redirect_to @article, notice: "Article ##{ctx.article.id} is now published!"
  rescue Easyop::Ctx::Failure => e
    redirect_to @article, alert: e.ctx.error
  end

  def destroy
    Articles::Destroy.call(article_id: @article.id, user: current_user)
      .on_success { |ctx| redirect_to articles_path, notice: "\"#{ctx.deleted_title}\" was deleted." }
      .on_failure { |ctx| redirect_to @article, alert: ctx.error }
  end

  private

  def set_article
    @article = Article.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to articles_path, alert: "Article not found."
  end

  def require_article_owner
    unless @article.user == current_user
      redirect_to @article, alert: "You can only modify your own articles."
    end
  end

  def article_params
    params.require(:article).permit(:title, :body)
      .merge(published: params.dig(:article, :published) == "1")
  end
end
