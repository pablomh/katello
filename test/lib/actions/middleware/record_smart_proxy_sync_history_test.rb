require 'katello_test_helper'

module Actions::Middleware
  class RecordSmartProxySyncHistoryPluralTest < ActiveSupport::TestCase
    include Dynflow::Testing
    include Support::Actions::Fixtures
    include Support::CapsuleSupport

    def setup
      super
      User.current = users(:admin)
    end

    def build_action(repository_ids:, smart_proxy: proxy_with_pulp)
      action = create_action(::Actions::Pulp3::CapsuleContent::Replicate)
      action.stubs(:input).returns(:smart_proxy_id => smart_proxy.id, :repository_ids => repository_ids)
      action
    end

    def build_middleware(action)
      middleware = ::Actions::Middleware::RecordSmartProxySyncHistory.allocate
      middleware.instance_variable_set(:@stack, stub(:action => action, :pass => nil))
      middleware
    end

    def test_repository_ids_dedups_duplicate_ids
      repo1 = katello_repositories(:fedora_17_x86_64)
      repo2 = katello_repositories(:rhel_7_x86_64)
      action = build_action(repository_ids: [repo1.id, repo2.id, repo1.id])

      assert_equal [repo1.id, repo2.id], build_middleware(action).repository_ids
    end

    def test_save_smart_proxy_sync_history_creates_a_history_row_per_distinct_repository
      repo1 = katello_repositories(:fedora_17_x86_64)
      repo2 = katello_repositories(:rhel_7_x86_64)
      action = build_action(repository_ids: [repo1.id, repo2.id, repo1.id])

      build_middleware(action).save_smart_proxy_sync_history

      assert_equal [repo1.id, repo2.id].sort,
        ::Katello::SmartProxySyncHistory.where(
          :smart_proxy_id => proxy_with_pulp.id, :repository_id => [repo1.id, repo2.id]
        ).pluck(:repository_id).sort
      assert_equal 2, action.output[:smart_proxy_history_ids].size
      refute action.output.key?(:smart_proxy_history_id)
    end

    def test_save_smart_proxy_sync_history_fails_when_a_repository_id_does_not_exist
      repo = katello_repositories(:fedora_17_x86_64)
      action = build_action(repository_ids: [repo.id, -1])

      assert_raises(RuntimeError) { build_middleware(action).save_smart_proxy_sync_history }
      assert_equal 0, ::Katello::SmartProxySyncHistory.where(
        :smart_proxy_id => proxy_with_pulp.id, :repository_id => repo.id
      ).count
    end

    def test_run_swallows_the_missing_repository_error_instead_of_raising
      repo = katello_repositories(:fedora_17_x86_64)
      action = build_action(repository_ids: [repo.id, -1])

      build_middleware(action).run

      assert_equal 0, ::Katello::SmartProxySyncHistory.where(
        :smart_proxy_id => proxy_with_pulp.id, :repository_id => repo.id
      ).count
    end
  end
end

module Actions::Helpers
  class SmartProxySyncHistoryHelperPluralTest < ActiveSupport::TestCase
    include Dynflow::Testing
    include Support::Actions::Fixtures
    include Support::CapsuleSupport

    def setup
      super
      User.current = users(:admin)
    end

    def test_rescue_external_task_deletes_unfinished_history_for_the_plural_case
      repo1 = katello_repositories(:fedora_17_x86_64)
      repo2 = katello_repositories(:rhel_7_x86_64)
      history_ids = ::Katello::SmartProxySyncHistory.bulk_start(
        :smart_proxy => proxy_with_pulp, :repository_ids => [repo1.id, repo2.id]
      )

      action = create_action(::Actions::Pulp3::CapsuleContent::Replicate)
      action.output[:smart_proxy_history_ids] = history_ids

      error = ::Katello::Errors::Pulp3Error.new('boom')
      assert_raises(::Katello::Errors::Pulp3Error) { action.rescue_external_task(error) }

      assert_equal 0, ::Katello::SmartProxySyncHistory.where(:id => history_ids).count
    end

    def test_rescue_external_task_leaves_already_finished_history_alone_for_the_plural_case
      repo1 = katello_repositories(:fedora_17_x86_64)
      repo2 = katello_repositories(:rhel_7_x86_64)
      history_ids = ::Katello::SmartProxySyncHistory.bulk_start(
        :smart_proxy => proxy_with_pulp, :repository_ids => [repo1.id, repo2.id]
      )
      ::Katello::SmartProxySyncHistory.where(:id => history_ids).update_all(:finished_at => Time.now)

      action = create_action(::Actions::Pulp3::CapsuleContent::Replicate)
      action.output[:smart_proxy_history_ids] = history_ids

      error = ::Katello::Errors::Pulp3Error.new('boom')
      assert_raises(::Katello::Errors::Pulp3Error) { action.rescue_external_task(error) }

      assert_equal 2, ::Katello::SmartProxySyncHistory.where(:id => history_ids).count
    end
  end
end
