# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CanCan::ModelAdapters::ActiveRecordAdapter do
  let(:true_v) do
    ActiveRecord::Base.connection.quoted_true
  end
  let(:false_v) do
    ActiveRecord::Base.connection.quoted_false
  end

  let(:false_condition) { "#{true_v}=#{false_v}" }

  before :each do
    connect_db
    ActiveRecord::Migration.verbose = false
    ActiveRecord::Schema.define do
      create_table(:categories) do |t|
        t.string :name
        t.boolean :visible
        t.timestamps null: false
      end

      create_table(:projects) do |t|
        t.string :name
        t.timestamps null: false
      end

      create_table(:companies) do |t|
        t.boolean :admin
      end

      create_table(:articles) do |t|
        t.string :name
        t.timestamps null: false
        t.boolean :published
        t.boolean :secret
        t.integer :priority
        t.integer :category_id
        t.integer :project_id
        t.integer :user_id
      end

      create_table(:comments) do |t|
        t.boolean :spam
        t.integer :article_id
        t.integer :project_id
        t.timestamps null: false
      end

      create_table(:legacy_comments) do |t|
        t.integer :post_id
        t.timestamps null: false
      end

      create_table(:legacy_mentions) do |t|
        t.integer :user_id
        t.integer :article_id
        t.timestamps null: false
      end

      create_table(:users) do |t|
        t.string :name
        t.timestamps null: false
      end
    end

    class Project < ActiveRecord::Base
      has_many :articles
      has_many :comments
    end

    class Category < ActiveRecord::Base
      has_many :articles
    end

    class Company < ActiveRecord::Base
    end

    class Article < ActiveRecord::Base
      belongs_to :category
      belongs_to :company
      has_many :comments
      has_many :mentions
      has_many :mentioned_users, through: :mentions, source: :user
      belongs_to :user
      belongs_to :project

      scope :unpopular, lambda {
        joins('LEFT OUTER JOIN comments ON (comments.post_id = posts.id)')
          .group('articles.id')
          .where('COUNT(comments.id) < 3')
      }
    end

    class Mention < ActiveRecord::Base
      self.table_name = 'legacy_mentions'
      belongs_to :user
      belongs_to :article
    end

    class Comment < ActiveRecord::Base
      belongs_to :article
      belongs_to :project
    end

    class LegacyComment < ActiveRecord::Base
      belongs_to :article, foreign_key: 'post_id'
      belongs_to :project
    end

    class User < ActiveRecord::Base
      has_many :articles
      has_many :mentions
      has_many :mentioned_articles, through: :mentions, source: :article
    end

    (@ability = double).extend(CanCan::Ability)
    @article_table = Article.table_name
    @comment_table = Comment.table_name
  end

  CanCan.valid_accessible_by_strategies.each do |strategy|
    context "base functionality with #{strategy} strategy" do
      before :each do
        CanCan.accessible_by_strategy = strategy
      end

      it 'does not fires query with accessible_by() for abilities defined with association' do
        user = User.create!
        @ability.can :edit, Article, user.articles.unpopular
        callback = ->(*) { raise 'No query expected' }

        ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
          Article.accessible_by(@ability, :edit)
          nil
        end
      end

      it 'fetches only the articles that are published' do
        @ability.can :read, Article, published: true
        article1 = Article.create!(published: true)
        Article.create!(published: false)
        expect(Article.accessible_by(@ability)).to eq([article1])
      end

      it 'is for only active record classes' do
        if ActiveRecord.version > Gem::Version.new('5')
          expect(CanCan::ModelAdapters::ActiveRecord5Adapter).to_not be_for_class(Object)
          expect(CanCan::ModelAdapters::ActiveRecord5Adapter).to be_for_class(Article)
          expect(CanCan::ModelAdapters::AbstractAdapter.adapter_class(Article))
            .to eq(CanCan::ModelAdapters::ActiveRecord5Adapter)
        elsif ActiveRecord.version > Gem::Version.new('4')
          expect(CanCan::ModelAdapters::ActiveRecord4Adapter).to_not be_for_class(Object)
          expect(CanCan::ModelAdapters::ActiveRecord4Adapter).to be_for_class(Article)
          expect(CanCan::ModelAdapters::AbstractAdapter.adapter_class(Article))
            .to eq(CanCan::ModelAdapters::ActiveRecord4Adapter)
        end
      end

      it 'finds record' do
        article = Article.create!
        adapter = CanCan::ModelAdapters::AbstractAdapter.adapter_class(Article)
        expect(adapter.find(Article, article.id)).to eq(article)
      end

      it 'does not fetch any records when no abilities are defined' do
        Article.create!
        expect(Article.accessible_by(@ability)).to be_empty
      end

      it 'fetches all articles when one can read all' do
        @ability.can :read, Article
        article = Article.create!
        expect(Article.accessible_by(@ability)).to match_array([article])
      end

      it 'fetches only the articles that are published' do
        @ability.can :read, Article, published: true
        article1 = Article.create!(published: true)
        Article.create!(published: false)
        expect(Article.accessible_by(@ability)).to match_array([article1])
      end

      it 'fetches any articles which are published or secret' do
        @ability.can :read, Article, published: true
        @ability.can :read, Article, secret: true
        article1 = Article.create!(published: true, secret: false)
        article2 = Article.create!(published: true, secret: true)
        article3 = Article.create!(published: false, secret: true)
        Article.create!(published: false, secret: false)
        expect(Article.accessible_by(@ability)).to match_array([article1, article2, article3])
      end

      it 'fetches any articles which we are cited in' do
        user = User.create!
        cited = Article.create!
        Article.create!
        cited.mentioned_users << user
        @ability.can :read, Article, mentioned_users: { id: user.id }
        @ability.can :read, Article, mentions: { user_id: user.id }
        expect(Article.accessible_by(@ability)).to match_array([cited])
      end

      it 'fetches only the articles that are published and not secret' do
        @ability.can :read, Article, published: true
        @ability.cannot :read, Article, secret: true
        article1 = Article.create!(published: true, secret: false)
        Article.create!(published: true, secret: true)
        Article.create!(published: false, secret: true)
        Article.create!(published: false, secret: false)
        expect(Article.accessible_by(@ability)).to match_array([article1])
      end

      it 'only reads comments for articles which are published' do
        @ability.can :read, Comment, article: { published: true }
        comment1 = Comment.create!(article: Article.create!(published: true))
        Comment.create!(article: Article.create!(published: false))
        expect(Comment.accessible_by(@ability)).to match_array([comment1])
      end

      it 'should only read articles which are published or in visible categories' do
        @ability.can :read, Article, category: { visible: true }
        @ability.can :read, Article, published: true
        article1 = Article.create!(published: true)
        Article.create!(published: false)
        article3 = Article.create!(published: false, category: Category.create!(visible: true))
        expect(Article.accessible_by(@ability)).to match_array([article1, article3])
      end

      it 'should only read categories once even if they have multiple articles' do
        @ability.can :read, Category, articles: { published: true }
        @ability.can :read, Article, published: true
        category = Category.create!
        Article.create!(published: true, category: category)
        Article.create!(published: true, category: category)
        expect(Category.accessible_by(@ability)).to match_array([category])
      end

      it 'only reads comments for visible categories through articles' do
        @ability.can :read, Comment, article: { category: { visible: true } }
        comment1 = Comment.create!(article: Article.create!(category: Category.create!(visible: true)))
        Comment.create!(article: Article.create!(category: Category.create!(visible: false)))
        expect(Comment.accessible_by(@ability)).to match_array([comment1])
        expect(Comment.accessible_by(@ability).count).to eq(1)
      end

      it 'allows conditions in SQL and merge with hash conditions' do
        @ability.can :read, Article, published: true
        @ability.can :read, Article, ['secret=?', true]
        article1 = Article.create!(published: true, secret: false)
        article2 = Article.create!(published: true, secret: true)
        article3 = Article.create!(published: false, secret: true)
        Article.create!(published: false, secret: false)
        expect(Article.accessible_by(@ability)).to match_array([article1, article2, article3])
      end

      it 'allows a scope for conditions' do
        @ability.can :read, Article, Article.where(secret: true)
        article1 = Article.create!(secret: true)
        Article.create!(secret: false)
        expect(Article.accessible_by(@ability)).to match_array([article1])
      end

      it 'fetches only associated records when using with a scope for conditions' do
        @ability.can :read, Article, Article.where(secret: true)
        category1 = Category.create!(visible: false)
        category2 = Category.create!(visible: true)
        article1 = Article.create!(secret: true, category: category1)
        Article.create!(secret: true, category: category2)
        expect(category1.articles.accessible_by(@ability)).to match_array([article1])
      end

      it 'raises an exception when trying to merge scope with other conditions' do
        @ability.can :read, Article, published: true
        @ability.can :read, Article, Article.where(secret: true)
        expect { Article.accessible_by(@ability) }
          .to raise_error(CanCan::Error,
                          'Unable to merge an Active Record scope with other conditions. '\
                            'Instead use a hash or SQL for read Article ability.')
      end

      it 'does not raise an exception when the rule with scope is suppressed' do
        @ability.can :read, Article, published: true
        @ability.can :read, Article, Article.where(secret: true)
        @ability.cannot :read, Article
        expect { Article.accessible_by(@ability) }.not_to raise_error
      end

      it 'recognises empty scopes and compresses them' do
        @ability.can :read, Article, published: true
        @ability.can :read, Article, Article.all
        expect { Article.accessible_by(@ability) }.not_to raise_error
      end

      it 'does not allow to fetch records when ability with just block present' do
        @ability.can :read, Article do
          false
        end
        expect { Article.accessible_by(@ability) }.to raise_error(CanCan::Error)
      end

      it 'should support more than one deeply nested conditions' do
        @ability.can :read, Comment, article: {
          category: {
            name: 'foo', visible: true
          }
        }
        expect { Comment.accessible_by(@ability) }.to_not raise_error
      end

      it 'does not allow to check ability on object against SQL conditions without block' do
        @ability.can :read, Article, ['secret=?', true]
        expect { @ability.can? :read, Article.new }.to raise_error(CanCan::Error)
      end

      it 'has false conditions if no abilities match' do
        expect(@ability.model_adapter(Article, :read).conditions).to eq(false_condition)
      end

      it 'returns false conditions for cannot clause' do
        @ability.cannot :read, Article
        expect(@ability.model_adapter(Article, :read).conditions).to eq(false_condition)
      end

      it 'returns SQL for single `can` definition in front of default `cannot` condition' do
        @ability.cannot :read, Article
        @ability.can :read, Article, published: false, secret: true
        expect(@ability.model_adapter(Article, :read)).to generate_sql(%(
    SELECT "articles".*
    FROM "articles"
    WHERE "articles"."published" = #{false_v} AND "articles"."secret" = #{true_v}))
      end

      it 'returns true condition for single `can` definition in front of default `can` condition' do
        @ability.can :read, Article
        @ability.can :read, Article, published: false, secret: true
        expect(@ability.model_adapter(Article, :read).conditions).to eq({})
        expect(@ability.model_adapter(Article, :read)).to generate_sql(%(SELECT "articles".* FROM "articles"))
      end

      it 'returns `false condition` for single `cannot` definition in front of default `cannot` condition' do
        @ability.cannot :read, Article
        @ability.cannot :read, Article, published: false, secret: true
        expect(@ability.model_adapter(Article, :read).conditions).to eq(false_condition)
      end

      it 'returns `not (sql)` for single `cannot` definition in front of default `can` condition' do
        @ability.can :read, Article
        @ability.cannot :read, Article, published: false, secret: true
        expect(@ability.model_adapter(Article, :read).conditions)
          .to orderlessly_match(
            %["not (#{@article_table}"."published" = #{false_v} AND "#{@article_table}"."secret" = #{true_v})]
          )
      end

      it 'returns appropriate sql conditions in complex case' do
        @ability.can :read, Article
        @ability.can :manage, Article, id: 1
        @ability.can :update, Article, published: true
        @ability.cannot :update, Article, secret: true
        expect(@ability.model_adapter(Article, :update).conditions)
          .to eq(%[not ("#{@article_table}"."secret" = #{true_v}) ] +
                   %[AND (("#{@article_table}"."published" = #{true_v}) ] +
                   %[OR ("#{@article_table}"."id" = 1))])
        expect(@ability.model_adapter(Article, :manage).conditions).to eq(id: 1)
        expect(@ability.model_adapter(Article, :read).conditions).to eq({})
        expect(@ability.model_adapter(Article, :read)).to generate_sql(%(SELECT "articles".* FROM "articles"))
      end

      it 'returns appropriate sql conditions in complex case with nested joins' do
        @ability.can :read, Comment, article: { category: { visible: true } }
        expect(@ability.model_adapter(Comment, :read).conditions).to eq(Category.table_name.to_sym => { visible: true })
      end

      it 'returns appropriate sql conditions in complex case with nested joins of different depth' do
        @ability.can :read, Comment, article: { published: true, category: { visible: true } }
        expect(@ability.model_adapter(Comment, :read).conditions)
          .to eq(Article.table_name.to_sym => { published: true }, Category.table_name.to_sym => { visible: true })
      end

      it 'does not forget conditions when calling with SQL string' do
        @ability.can :read, Article, published: true
        @ability.can :read, Article, ['secret = ?', false]
        adapter = @ability.model_adapter(Article, :read)
        2.times do
          expect(adapter.conditions).to eq(%[(secret = #{false_v}) OR ("#{@article_table}"."published" = #{true_v})])
        end
      end

      it 'has nil joins if no rules' do
        expect(@ability.model_adapter(Article, :read).joins).to be_nil
      end

      it 'has nil joins if rules got compressed' do
        @ability.can :read, Comment, article: { category: { visible: true } }
        @ability.can :read, Comment
        expect(@ability.model_adapter(Comment, :read))
          .to generate_sql("SELECT \"#{@comment_table}\".* FROM \"#{@comment_table}\"")
        expect(@ability.model_adapter(Comment, :read).joins).to be_nil
      end

      it 'has nil joins if no nested hashes specified in conditions' do
        @ability.can :read, Article, published: false
        @ability.can :read, Article, secret: true
        expect(@ability.model_adapter(Article, :read).joins).to be_nil
      end

      it 'merges separate joins into a single array' do
        @ability.can :read, Article, project: { blocked: false }
        @ability.can :read, Article, company: { admin: true }
        expect(@ability.model_adapter(Article, :read).joins.inspect).to orderlessly_match(%i[company project].inspect)
      end

      it 'merges same joins into a single array' do
        @ability.can :read, Article, project: { blocked: false }
        @ability.can :read, Article, project: { admin: true }
        expect(@ability.model_adapter(Article, :read).joins).to eq([:project])
      end

      it 'merges nested and non-nested joins' do
        @ability.can :read, Article, project: { blocked: false }
        @ability.can :read, Article, project: { comments: { spam: true } }
        expect(@ability.model_adapter(Article, :read).joins).to eq([{ project: [:comments] }])
      end

      it 'merges :all conditions with other conditions' do
        user = User.create!
        article = Article.create!(user: user)
        ability = Ability.new(user)
        ability.can :manage, :all
        ability.can :manage, Article, user_id: user.id
        expect(Article.accessible_by(ability)).to eq([article])
      end

      it 'should not execute a scope when checking ability on the class' do
        relation = Article.where(secret: true)
        @ability.can :read, Article, relation do |article|
          article.secret == true
        end

        allow(relation).to receive(:count).and_raise('Unexpected scope execution.')

        expect { @ability.can? :read, Article }.not_to raise_error
      end

      it 'should ignore cannot rules with attributes when querying' do
        user = User.create!
        article = Article.create!(user: user)
        ability = Ability.new(user)
        ability.can :read, Article
        ability.cannot :read, Article, :secret
        expect(Article.accessible_by(ability)).to eq([article])
      end

      describe 'when can? is used with a Hash (nested resources)' do
        it 'verifies parent equality correctly' do
          user1 = User.create!(name: 'user1')
          user2 = User.create!(name: 'user2')
          category = Category.create!(name: 'cat')
          article1 = Article.create!(name: 'article1', category: category, user: user1)
          article2 = Article.create!(name: 'article2', category: category, user: user2)
          comment1 = Comment.create!(article: article1)
          comment2 = Comment.create!(article: article2)

          ability1 = Ability.new(user1)
          ability1.can :read, Article
          ability1.can :manage, Article, user: user1
          ability1.can :manage, Comment, article: user1.articles

          expect(ability1.can?(:manage, { article1 => Comment })).to eq(true)
          expect(ability1.can?(:manage, { article2 => Comment })).to eq(false)
          expect(ability1.can?(:manage, { article1 => comment1 })).to eq(true)
          expect(ability1.can?(:manage, { article2 => comment2 })).to eq(false)

          ability2 = Ability.new(user2)

          expect(ability2.can?(:manage, { article1 => Comment })).to eq(false)
          expect(ability2.can?(:manage, { article2 => Comment })).to eq(false)
          expect(ability2.can?(:manage, { article1 => comment1 })).to eq(false)
          expect(ability2.can?(:manage, { article2 => comment2 })).to eq(false)
        end
      end
    end
  end

  describe 'when can? is used with a Hash (nested resources)' do
    let(:user1) { User.create!(name: 'user1') }
    let(:user2) { User.create!(name: 'user2') }

    before do
      category = Category.create!(name: 'category')
      @article1 = Article.create!(name: 'article1', category: category, user: user1)
      @article2 = Article.create!(name: 'article2', category: category, user: user2)
      @comment1 = Comment.create!(article: @article1)
      @comment2 = Comment.create!(article: @article2)
      @legacy_comment1 = LegacyComment.create!(article: @article1)
      @legacy_comment2 = LegacyComment.create!(article: @article2)
    end

    context 'when conditions are defined using the parent model' do
      let(:ability) do
        Ability.new(user1).tap do |ability|
          ability.can :read, Article
          ability.can :manage, Article, user: user1
          ability.can :manage, Comment, article: user1.articles
          ability.can :manage, LegacyComment, article: user1.articles
        end
      end

      it 'verifies parent equality correctly' do
        expect(ability.can?(:manage, { @article1 => Comment })).to eq(true)
        expect(ability.can?(:manage, { @article1 => LegacyComment })).to eq(true)
        expect(ability.can?(:manage, { @article1 => @comment1 })).to eq(true)
        expect(ability.can?(:manage, { @article1 => @legacy_comment1 })).to eq(true)

        expect(ability.can?(:manage, { @article2 => Comment })).to eq(false)
        expect(ability.can?(:manage, { @article2 => LegacyComment })).to eq(false)
        expect(ability.can?(:manage, { @article2 => @legacy_comment2 })).to eq(false)
      end
    end

    context 'when conditions are defined using the parent id' do
      let(:ability) do
        Ability.new(user1).tap do |ability|
          ability.can :read, Article
          ability.can :manage, Article, user_id: user1.id
          ability.can :manage, Comment, article_id: user1.article_ids
          ability.can :manage, LegacyComment, post_id: user1.article_ids
        end
      end

      it 'verifies parent equality correctly' do
        expect(ability.can?(:manage, { @article1 => Comment })).to eq(true)
        expect(ability.can?(:manage, { @article1 => LegacyComment })).to eq(true)
        expect(ability.can?(:manage, { @article1 => @comment1 })).to eq(true)
        expect(ability.can?(:manage, { @article1 => @legacy_comment1 })).to eq(true)

        expect(ability.can?(:manage, { @article2 => Comment })).to eq(false)
        expect(ability.can?(:manage, { @article2 => LegacyComment })).to eq(false)
        expect(ability.can?(:manage, { @article2 => @legacy_comment2 })).to eq(false)
      end
    end
  end

  unless CanCan::ModelAdapters::ActiveRecordAdapter.version_lower?('5.0.0')
    context 'base behaviour subquery specific' do
      before :each do
        CanCan.accessible_by_strategy = :subquery
      end

      it 'allows ordering via relations' do
        @ability.can :read, Comment, article: { category: { visible: true } }
        comment1 = Comment.create!(article: Article.create!(name: 'B', category: Category.create!(visible: true)))
        comment2 = Comment.create!(article: Article.create!(name: 'A', category: Category.create!(visible: true)))
        Comment.create!(article: Article.create!(category: Category.create!(visible: false)))

        # doesn't work without explicitly calling a join on AR 5+,
        # but does before that (where we don't use subqueries at all)
        if CanCan::ModelAdapters::ActiveRecordAdapter.version_greater_or_equal?('5.0.0')
          expect { Comment.accessible_by(@ability).order('articles.name').to_a }
            .to raise_error(ActiveRecord::StatementInvalid)
        else
          expect(Comment.accessible_by(@ability).order('articles.name'))
            .to match_array([comment2, comment1])
        end

        # works with the explicit join
        expect(Comment.accessible_by(@ability).joins(:article).order('articles.name'))
          .to match_array([comment2, comment1])
      end
    end
  end

  context 'base behaviour left_join specific' do
    before :each do
      CanCan.accessible_by_strategy = :left_join
    end

    it 'allows ordering via relations in sqlite' do
      skip unless sqlite?

      @ability.can :read, Comment, article: { category: { visible: true } }
      comment1 = Comment.create!(article: Article.create!(name: 'B', category: Category.create!(visible: true)))
      comment2 = Comment.create!(article: Article.create!(name: 'A', category: Category.create!(visible: true)))
      Comment.create!(article: Article.create!(category: Category.create!(visible: false)))

      # works without explicitly calling a join
      expect(Comment.accessible_by(@ability).order('articles.name')).to match_array([comment2, comment1])

      # works with the explicit join in AR 5.2+ and AR 4.2
      if CanCan::ModelAdapters::ActiveRecordAdapter.version_greater_or_equal?('5.2.0')
        expect(Comment.accessible_by(@ability).joins(:article).order('articles.name'))
          .to match_array([comment2, comment1])
      elsif CanCan::ModelAdapters::ActiveRecordAdapter.version_greater_or_equal?('5.0.0')
        expect { Comment.accessible_by(@ability).joins(:article).order('articles.name').to_a }
          .to raise_error(ActiveRecord::StatementInvalid)
      else
        expect(Comment.accessible_by(@ability).joins(:article).order('articles.name'))
          .to match_array([comment2, comment1])
      end
    end

    # this fails on Postgres. see https://github.com/CanCanCommunity/cancancan/pull/608
    it 'fails to order via relations in postgres on AR 5+' do
      skip unless postgres?

      @ability.can :read, Comment, article: { category: { visible: true } }
      comment1 = Comment.create!(article: Article.create!(name: 'B', category: Category.create!(visible: true)))
      comment2 = Comment.create!(article: Article.create!(name: 'A', category: Category.create!(visible: true)))
      Comment.create!(article: Article.create!(category: Category.create!(visible: false)))

      if CanCan::ModelAdapters::ActiveRecordAdapter.version_greater_or_equal?('5.0.0')
        # doesn't work with or without the join
        expect { Comment.accessible_by(@ability).order('articles.name').to_a }
          .to raise_error(ActiveRecord::StatementInvalid)
        expect { Comment.accessible_by(@ability).joins(:article).order('articles.name').to_a }
          .to raise_error(ActiveRecord::StatementInvalid)
      else
        expect(Comment.accessible_by(@ability).order('articles.name'))
          .to match_array([comment2, comment1])
        expect(Comment.accessible_by(@ability).joins(:article).order('articles.name'))
          .to match_array([comment2, comment1])
      end
    end
  end

  context 'with namespaced models' do
    before :each do
      ActiveRecord::Schema.define do
        create_table(:table_xes) do |t|
          t.timestamps null: false
        end

        create_table(:table_zs) do |t|
          t.integer :table_x_id
          t.integer :user_id
          t.timestamps null: false
        end
      end

      module Namespace
      end

      class Namespace::TableX < ActiveRecord::Base
        has_many :table_zs
      end

      class Namespace::TableZ < ActiveRecord::Base
        belongs_to :table_x
        belongs_to :user
      end
    end

    it 'fetches all namespace::table_x when one is related by table_y' do
      user = User.create!

      ability = Ability.new(user)
      ability.can :read, Namespace::TableX, table_zs: { user_id: user.id }

      table_x = Namespace::TableX.create!
      table_x.table_zs.create(user: user)
      expect(Namespace::TableX.accessible_by(ability)).to match_array([table_x])
    end
  end

  context 'when conditions are non iterable ranges' do
    before :each do
      ActiveRecord::Schema.define do
        create_table(:courses) do |t|
          t.datetime :start_at
        end
      end

      class Course < ActiveRecord::Base
      end
    end

    it 'fetches only the valid records' do
      @ability.can :read, Course, start_at: 1.day.ago..1.day.from_now
      Course.create!(start_at: 10.days.ago)
      valid_course = Course.create!(start_at: Time.now)

      expect(Course.accessible_by(@ability)).to match_array([valid_course])
    end
  end

  context 'when an association is used to create a rule' do
    before do
      ActiveRecord::Schema.define do
        create_table(:foos) do |t|
          t.string :name
        end
        create_table(:bars) do |t|
          t.string :name
        end
        create_table :roles do |t|
          t.string :name

          t.timestamps
        end
        create_table :user_roles do |t|
          t.references :user, foreign_key: true
          t.references :role, foreign_key: true
          t.references :subject, polymorphic: true

          t.timestamps
        end
      end

      class Foo < ActiveRecord::Base
        has_many :user_roles, as: :subject
      end

      class Bar < ActiveRecord::Base
        has_many :user_roles, as: :subject
      end

      class Role < ActiveRecord::Base
        has_many :user_roles
        has_many :users, through: :user_roles
        has_many :foos, through: :user_roles
        has_many :bars, through: :user_roles
      end

      class UserRole < ActiveRecord::Base
        belongs_to :user
        belongs_to :role
        belongs_to :subject, polymorphic: true, required: false
      end
    end

    it 'allows for access with association' do
      user = User.create!
      foo = Foo.create(name: 'foo')
      role = Role.create(name: 'adviser')
      UserRole.create(user: user, role: role, subject: foo)
      ability = Ability.new(user)
      ability.can :read, Foo, user_roles: { user: user }
      expect(ability.can?(:read, Foo)).to eq(true)
    end

    it 'allows for access with association with accessible_by' do
      user = User.new
      foo = Foo.create(name: 'foo')
      bar = Bar.create(name: 'bar')
      role = Role.create(name: 'adviser')
      UserRole.create(user: user, role: role, subject: foo)
      UserRole.create(user: user, role: role, subject: bar)
      ability = Ability.new(user)
      ability.can :read, Foo, user_roles: { user: user }
      expect(Foo.accessible_by(ability)).to match_array([foo])
      expect(Bar.accessible_by(ability)).to match_array([])
    end

    it 'blocks access with association' do
      user = User.create!
      foo = Foo.create(name: 'foo')
      role = Role.create(name: 'adviser')
      UserRole.create(user: user, role: role, subject: foo)
      ability = Ability.new(user)
      ability.cannot :read, Foo, user_roles: { user: user }
      expect(ability.can?(:read, Foo)).to eq(false)
    end

    it 'blocks access with association for accessible_by' do
      user = User.create!
      foo = Foo.create(name: 'foo')
      role = Role.create(name: 'adviser')
      UserRole.create(user: user, role: role, subject: foo)
      ability = Ability.new(user)
      ability.cannot :read, Foo, user_roles: { user: user }
      expect(Foo.accessible_by(ability)).to match_array([])
      expect(ability.can?(:read, Foo)).to eq(false)
    end

    it 'manages access with multiple models and users' do
      (0..5).each do |index|
        user = User.create!
        foo = Foo.create(name: 'foo')
        role = Role.create(name: "adviser_#{index}")
        UserRole.create(user: user, role: role, subject: foo)
      end

      user = User.first

      Foo.all.each do |foo|
        role = Role.create(name: 'new_user')
        UserRole.create(user: user, role: role, subject: foo)
      end

      ability = Ability.new(user)
      ability.can :read, Foo, user_roles: { user: user }
      expect(Foo.accessible_by(ability).count).to eq(Foo.count)

      User.where.not(id: user.id).each do |limited_permission_user|
        ability = Ability.new(limited_permission_user)
        expect(ability.can?(:read, Foo)).to eq(false)
        expect(Foo.accessible_by(ability).count).to eq(0)
        ability.can :read, Foo, user_roles: { user: limited_permission_user }
        expect(ability.can?(:read, Foo)).to eq(true)
        expect(Foo.accessible_by(ability).count).to eq(1)
      end
    end
  end

  context 'when a table references another one twice' do
    before do
      ActiveRecord::Schema.define do
        create_table(:transactions) do |t|
          t.integer :sender_id
          t.integer :receiver_id
        end
      end

      class Transaction < ActiveRecord::Base
        belongs_to :sender, class_name: 'User', foreign_key: :sender_id
        belongs_to :receiver, class_name: 'User', foreign_key: :receiver_id
      end
    end

    it 'can filter correctly on both associations' do
      sender = User.create!
      receiver = User.create!
      t1 = Transaction.create!(sender: sender, receiver: receiver)
      t2 = Transaction.create!(sender: receiver, receiver: sender)

      ability = Ability.new(sender)
      ability.can :read, Transaction, sender: { id: sender.id }
      ability.can :read, Transaction, receiver: { id: sender.id }
      expect(Transaction.accessible_by(ability)).to match_array([t1, t2])
    end
  end

  CanCan.valid_accessible_by_strategies.each do |strategy|
    context "when a table is referenced multiple times with #{strategy} strategy" do
      before :each do
        CanCan.accessible_by_strategy = strategy
      end
      it 'can filter correctly on the different associations' do
        u1 = User.create!(name: 'pippo')
        u2 = User.create!(name: 'paperino')

        a1 = Article.create!(user: u1)
        a2 = Article.create!(user: u2)

        ability = Ability.new(u1)
        ability.can :read, Article, user: { id: u1.id }
        ability.can :read, Article, mentioned_users: { name: u1.name }
        ability.can :read, Article, mentioned_users: { mentioned_articles: { id: a2.id } }
        ability.can :read, Article, mentioned_users: { articles: { user: { name: 'deep' } } }
        ability.can :read, Article, mentioned_users: { articles: { mentioned_users: { name: 'd2' } } }
        expect(Article.accessible_by(ability)).to match_array([a1])
      end
    end
  end

  unless CanCan::ModelAdapters::ActiveRecordAdapter.version_lower?('5.0.0')
    context 'has_many through is defined and referenced differently - subquery strategy' do
      before do
        CanCan.accessible_by_strategy = :subquery
      end

      it 'recognises it and simplifies the query' do
        u1 = User.create!(name: 'pippo')
        u2 = User.create!(name: 'paperino')

        a1 = Article.create!(mentioned_users: [u1])
        a2 = Article.create!(mentioned_users: [u2])

        ability = Ability.new(u1)
        ability.can :read, Article, mentioned_users: { name: u1.name }
        ability.can :read, Article, mentions: { user: { name: u2.name } }
        expect(Article.accessible_by(ability)).to match_array([a1, a2])
        if CanCan::ModelAdapters::ActiveRecordAdapter.version_greater_or_equal?('5.0.0')
          expect(ability.model_adapter(Article, :read)).to generate_sql(%(
    SELECT "articles".*
    FROM "articles"
    WHERE "articles"."id" IN
    (SELECT "articles"."id"
      FROM "articles"
      LEFT OUTER JOIN "legacy_mentions" ON "legacy_mentions"."article_id" = "articles"."id"
      LEFT OUTER JOIN "users" ON "users"."id" = "legacy_mentions"."user_id"
      WHERE (("users"."name" = 'paperino') OR ("users"."name" = 'pippo')))
    ))
        end
      end
    end
  end

  context 'has_many through is defined and referenced differently - left_join strategy' do
    before do
      CanCan.accessible_by_strategy = :left_join
    end

    it 'recognises it and simplifies the query' do
      u1 = User.create!(name: 'pippo')
      u2 = User.create!(name: 'paperino')

      a1 = Article.create!(mentioned_users: [u1])
      a2 = Article.create!(mentioned_users: [u2])

      ability = Ability.new(u1)
      ability.can :read, Article, mentioned_users: { name: u1.name }
      ability.can :read, Article, mentions: { user: { name: u2.name } }
      expect(Article.accessible_by(ability)).to match_array([a1, a2])

      if CanCan::ModelAdapters::ActiveRecordAdapter.version_greater_or_equal?('5.0.0')
        expect(ability.model_adapter(Article, :read)).to generate_sql(%(
  SELECT DISTINCT "articles".*
  FROM "articles"
  LEFT OUTER JOIN "legacy_mentions" ON "legacy_mentions"."article_id" = "articles"."id"
  LEFT OUTER JOIN "users" ON "users"."id" = "legacy_mentions"."user_id"
  WHERE (("users"."name" = 'paperino') OR ("users"."name" = 'pippo'))))
      end
    end
  end

  if CanCan::ModelAdapters::ActiveRecordAdapter.version_greater_or_equal?('5.0.0')
    context 'switching strategies' do
      before do
        CanCan.accessible_by_strategy = :left_join # default - should be ignored in these tests
      end

      it 'allows you to switch strategies with a keyword argument' do
        u = User.create!(name: 'pippo')
        Article.create!(mentioned_users: [u])

        ability = Ability.new(u)
        ability.can :read, Article, mentions: { user: { name: u.name } }

        subquery_sql = Article.accessible_by(ability, strategy: :subquery).to_sql
        left_join_sql = Article.accessible_by(ability, strategy: :left_join).to_sql

        expect(subquery_sql.strip.squeeze(' ')).to eq(%(
    SELECT "articles".*
    FROM "articles"
    WHERE "articles"."id" IN
    (SELECT "articles"."id"
      FROM "articles"
      LEFT OUTER JOIN "legacy_mentions" ON "legacy_mentions"."article_id" = "articles"."id"
      LEFT OUTER JOIN "users" ON "users"."id" = "legacy_mentions"."user_id"
      WHERE "users"."name" = 'pippo')
    ).gsub(/\s+/, ' ').strip)

        expect(left_join_sql.strip.squeeze(' ')).to eq(%(
  SELECT DISTINCT "articles".*
  FROM "articles"
  LEFT OUTER JOIN "legacy_mentions" ON "legacy_mentions"."article_id" = "articles"."id"
  LEFT OUTER JOIN "users" ON "users"."id" = "legacy_mentions"."user_id"
  WHERE "users"."name" = 'pippo').gsub(/\s+/, ' ').strip)
      end

      it 'allows you to switch strategies with a block' do
        u = User.create!(name: 'pippo')
        Article.create!(mentioned_users: [u])

        ability = Ability.new(u)
        ability.can :read, Article, mentions: { user: { name: u.name } }

        subquery_sql = CanCan.with_accessible_by_strategy(:subquery) { Article.accessible_by(ability).to_sql }
        left_join_sql = CanCan.with_accessible_by_strategy(:left_join) { Article.accessible_by(ability).to_sql }

        expect(subquery_sql.strip.squeeze(' ')).to eq(%(
    SELECT "articles".*
    FROM "articles"
    WHERE "articles"."id" IN
    (SELECT "articles"."id"
      FROM "articles"
      LEFT OUTER JOIN "legacy_mentions" ON "legacy_mentions"."article_id" = "articles"."id"
      LEFT OUTER JOIN "users" ON "users"."id" = "legacy_mentions"."user_id"
      WHERE "users"."name" = 'pippo')
    ).gsub(/\s+/, ' ').strip)

        expect(left_join_sql.strip.squeeze(' ')).to eq(%(
  SELECT DISTINCT "articles".*
  FROM "articles"
  LEFT OUTER JOIN "legacy_mentions" ON "legacy_mentions"."article_id" = "articles"."id"
  LEFT OUTER JOIN "users" ON "users"."id" = "legacy_mentions"."user_id"
  WHERE "users"."name" = 'pippo').gsub(/\s+/, ' ').strip)
      end

      it 'allows you to switch strategies with a block, and to_sql called outside the block' do
        u = User.create!(name: 'pippo')
        Article.create!(mentioned_users: [u])

        ability = Ability.new(u)
        ability.can :read, Article, mentions: { user: { name: u.name } }

        subquery_sql = CanCan.with_accessible_by_strategy(:subquery) { Article.accessible_by(ability) }.to_sql
        left_join_sql = CanCan.with_accessible_by_strategy(:left_join) { Article.accessible_by(ability) }.to_sql

        expect(subquery_sql.strip.squeeze(' ')).to eq(%(
    SELECT "articles".*
    FROM "articles"
    WHERE "articles"."id" IN
    (SELECT "articles"."id"
      FROM "articles"
      LEFT OUTER JOIN "legacy_mentions" ON "legacy_mentions"."article_id" = "articles"."id"
      LEFT OUTER JOIN "users" ON "users"."id" = "legacy_mentions"."user_id"
      WHERE "users"."name" = 'pippo')
    ).gsub(/\s+/, ' ').strip)

        expect(left_join_sql.strip.squeeze(' ')).to eq(%(
  SELECT DISTINCT "articles".*
  FROM "articles"
  LEFT OUTER JOIN "legacy_mentions" ON "legacy_mentions"."article_id" = "articles"."id"
  LEFT OUTER JOIN "users" ON "users"."id" = "legacy_mentions"."user_id"
  WHERE "users"."name" = 'pippo').gsub(/\s+/, ' ').strip)
      end
    end
  end

  CanCan.valid_accessible_by_strategies.each do |strategy|
    context "when a model has renamed primary_key with #{strategy} strategy" do
      before :each do
        CanCan.accessible_by_strategy = strategy
      end
      before do
        ActiveRecord::Schema.define do
          create_table(:custom_pk_users, primary_key: :gid) do |t|
            t.string :name
          end

          create_table(:custom_pk_transactions, primary_key: :gid) do |t|
            t.integer :custom_pk_user_id
            t.string :data
          end
        end

        class CustomPkUser < ActiveRecord::Base
          self.primary_key = 'gid'
        end

        class CustomPkTransaction < ActiveRecord::Base
          self.primary_key = 'gid'

          belongs_to :custom_pk_user
        end
      end

      it 'can filter correctly' do
        user1 = CustomPkUser.create!
        user2 = CustomPkUser.create!

        transaction1 = CustomPkTransaction.create!(custom_pk_user: user1)
        CustomPkTransaction.create!(custom_pk_user: user2)

        ability = Ability.new(user1)
        ability.can :read, CustomPkTransaction, custom_pk_user: { gid: user1.gid }

        expect(CustomPkTransaction.accessible_by(ability)).to match_array([transaction1])
      end
    end
  end

  context 'when a table has json type column' do
    before do
      json_supported =
        ActiveRecord::Base.connection.respond_to?(:supports_json?) &&
        ActiveRecord::Base.connection.supports_json?

      skip "Adapter don't support JSON column type" unless json_supported

      ActiveRecord::Schema.define do
        create_table(:json_transactions) do |t|
          t.integer :user_id
          t.json :additional_data
        end
      end

      class JsonTransaction < ActiveRecord::Base
        belongs_to :user
      end
    end

    it 'can filter correctly if using subquery strategy' do
      CanCan.accessible_by_strategy = :subquery

      user = User.create!
      transaction = JsonTransaction.create!(user: user)

      ability = Ability.new(user)
      ability.can :read, JsonTransaction, user: { id: user.id }

      expect(JsonTransaction.accessible_by(ability)).to match_array([transaction])
    end

    # this fails on Postgres. see https://github.com/CanCanCommunity/cancancan/pull/608
    it 'cannot filter JSON on postgres columns using left_join strategy' do
      skip unless postgres?

      CanCan.accessible_by_strategy = :left_join

      user = User.create!
      JsonTransaction.create!(user: user)

      ability = Ability.new(user)
      ability.can :read, JsonTransaction, user: { id: user.id }

      expect { JsonTransaction.accessible_by(ability).to_a }
        .to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  context 'with rule application to subclass for non sti class' do
    before do
      ActiveRecord::Schema.define do
        create_table :parents, force: true

        create_table :children, force: true
      end

      class ApplicationRecord < ActiveRecord::Base
        self.abstract_class = true
      end

      class Parent < ActiveRecord::Base
      end

      class Child < Parent
      end
    end

    it 'cannot rules are not effecting parent class' do
      u1 = User.create!(name: 'pippo')
      ability = Ability.new(u1)
      ability.can :manage, Parent
      ability.cannot :manage, Child
      expect(ability).not_to be_able_to(:index, Child)
      expect(ability).to be_able_to(:index, Parent)
    end

    it 'can rules are not effecting parent class' do
      u1 = User.create!(name: 'pippo')
      ability = Ability.new(u1)
      ability.can :manage, Child
      expect(ability).to be_able_to(:index, Child)
      expect(ability).not_to be_able_to(:index, Parent)
    end
  end

  context 'when STI is in use' do
    before do
      ActiveRecord::Schema.define do
        create_table(:brands) do |t|
          t.string :name
        end

        create_table(:vehicles) do |t|
          t.string :type
        end
      end

      class ApplicationRecord < ActiveRecord::Base
        self.abstract_class = true
      end

      class Vehicle < ApplicationRecord
      end

      class Car < Vehicle
      end

      class Motorbike < Vehicle
      end

      class Suzuki < Motorbike
      end
    end

    it 'recognises rules applied to the base class' do
      u1 = User.create!(name: 'pippo')

      car = Car.create!
      motorbike = Motorbike.create!

      ability = Ability.new(u1)
      ability.can :read, Vehicle
      expect(Vehicle.accessible_by(ability)).to match_array([car, motorbike])
      expect(Car.accessible_by(ability)).to match_array([car])
      expect(Motorbike.accessible_by(ability)).to match_array([motorbike])
    end

    it 'recognises rules applied to the base class multiple classes deep' do
      u1 = User.create!(name: 'pippo')

      car = Car.create!
      motorbike = Motorbike.create!
      suzuki = Suzuki.create!

      ability = Ability.new(u1)
      ability.can :read, Vehicle
      expect(Vehicle.accessible_by(ability)).to match_array([suzuki, car, motorbike])
      expect(Car.accessible_by(ability)).to match_array([car])
      expect(Motorbike.accessible_by(ability)).to match_array([suzuki, motorbike])
      expect(Suzuki.accessible_by(ability)).to match_array([suzuki])
    end

    it 'recognises rules applied to subclasses' do
      u1 = User.create!(name: 'pippo')
      car = Car.create!
      Motorbike.create!

      ability = Ability.new(u1)
      ability.can :read, [Car]
      expect(Vehicle.accessible_by(ability)).to match_array([car])
      expect(Car.accessible_by(ability)).to eq([car])
      expect(Motorbike.accessible_by(ability)).to eq([])
    end

    it 'recognises rules applied to subclasses on 3 level' do
      u1 = User.create!(name: 'pippo')
      suzuki = Suzuki.create!
      Motorbike.create!
      ability = Ability.new(u1)
      ability.can :read, [Suzuki]
      expect(Motorbike.accessible_by(ability)).to eq([suzuki])
    end

    it 'recognises rules applied to subclass of subclass even with be_able_to' do
      u1 = User.create!(name: 'pippo')
      motorbike = Motorbike.create!
      ability = Ability.new(u1)
      ability.can :read, [Motorbike]
      expect(ability).to be_able_to(:read, motorbike)
      expect(ability).to be_able_to(:read, Suzuki.new)
    end
  end
end
