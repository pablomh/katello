require 'katello_test_helper'

module ::Actions::Katello::CapsuleContent
  class TestBase < ActiveSupport::TestCase
    include Dynflow::Testing
    include Support::Actions::Fixtures
    include FactoryBot::Syntax::Methods
    include Support::CapsuleSupport
    include Support::Actions::RemoteAction

    let(:environment) do
      katello_environments(:library)
    end

    let(:repository) do
      katello_repositories(:fedora_17_x86_64_dev)
    end

    let(:custom_repository) do
      katello_repositories(:fedora_17_x86_64)
    end

    before do
      set_user
      SmartProxy.any_instance.stubs(:ping_pulp3).returns({})
      SmartProxy.any_instance.stubs(:pulp3_configuration).returns(nil)
      SmartProxy.any_instance.stubs(:verify_ueber_certs).returns(nil)
      ::Katello::Pulp3::Api::ContentGuard.any_instance.stubs(:list).returns(nil)
      ::Katello::Pulp3::Api::ContentGuard.any_instance.stubs(:create).returns(nil)
    end
  end

  class SyncTest < TestBase
    let(:action_class) { ::Actions::Katello::CapsuleContent::Sync }
    let(:staging_environment) { katello_environments(:staging) }
    let(:dev_environment) { katello_environments(:dev) }

    before do
      SmartProxy.any_instance.stubs(:pulp_primary?).returns(false)
    end

    it 'plans correctly for a pulp3 file repo' do
      with_pulp3_features(capsule_content.smart_proxy)
      capsule_content.smart_proxy.add_lifecycle_environment(environment)
      repo = katello_repositories(:pulp3_file_1)
      repo.root.update_attribute(:unprotected, true)
      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :repository_id => repo.id)
      options = { smart_proxy_id: capsule_content.smart_proxy.id,
                  content_view_id: nil,
                  repository_id: repo.id,
                  repository_ids_list: nil,
                  environment_id: nil,
                }
      assert_tree_planned_with(tree, ::Actions::Pulp3::Orchestration::Repository::RefreshRepos, options)
      assert_tree_planned_steps(tree, ::Actions::Pulp3::ContentGuard::Refresh)
      assert_tree_planned_with(tree, ::Actions::Pulp3::CapsuleContent::Sync) do |input|
        assert_equal capsule_content.smart_proxy.id, input[:smart_proxy_id]
        assert_equal repo.id, input[:repository_id]
      end

      assert_tree_planned_with(tree, ::Actions::Pulp3::CapsuleContent::GenerateMetadata) do |input|
        assert_equal capsule_content.smart_proxy.id, input[:smart_proxy_id]
        assert_equal repo.id, input[:repository_id]
      end

      assert_refresh_boundary(tree, [repo.id])
    end

    it 'plans correctly for a pulp3 yum repo without the proper plugin' do
      with_pulp3_features(capsule_content.smart_proxy)
      capsule_content.smart_proxy.add_lifecycle_environment(environment)
      capsule_content.smart_proxy.stubs(:capabilities).returns([])
      repo = katello_repositories(:fedora_17_x86_64)
      repo.root.update_attribute(:unprotected, true)
      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :repository_id => repo.id)
      refute_tree_planned(tree, ::Actions::Pulp3::CapsuleContent::Sync)
      refute_tree_planned(tree, Actions::Pulp3::CapsuleContent::RefreshDistribution)
      refute_tree_planned(tree, Actions::Pulp3::CapsuleContent::RefreshAllDistributions)
    end

    it 'plans correctly for a pulp3 yum repo' do
      with_pulp3_features(capsule_content.smart_proxy)
      capsule_content.smart_proxy.add_lifecycle_environment(environment)
      repo = katello_repositories(:fedora_17_x86_64)
      repo.root.update_attribute(:unprotected, true)
      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :repository_id => repo.id)
      options = { smart_proxy_id: capsule_content.smart_proxy.id,
                  content_view_id: nil,
                  repository_id: repo.id,
                  repository_ids_list: nil,
                  environment_id: nil,
      }
      assert_tree_planned_with(tree, ::Actions::Pulp3::Orchestration::Repository::RefreshRepos, options)
      assert_tree_planned_steps(tree, ::Actions::Pulp3::ContentGuard::Refresh)
      assert_tree_planned_with(tree, ::Actions::Pulp3::CapsuleContent::Sync) do |input|
        assert_equal capsule_content.smart_proxy.id, input[:smart_proxy_id]
        assert_equal repo.id, input[:repository_id]
      end

      assert_tree_planned_with(tree, ::Actions::Pulp3::CapsuleContent::GenerateMetadata) do |input|
        assert_equal capsule_content.smart_proxy.id, input[:smart_proxy_id]
        assert_equal repo.id, input[:repository_id]
      end

      assert_refresh_boundary(tree, [repo.id])
    end

    it 'skips repos with finished sync history from sync and cutover planning' do
      with_pulp3_features(capsule_content.smart_proxy)
      capsule_content.smart_proxy.add_lifecycle_environment(environment)
      repo = katello_repositories(:fedora_17_x86_64)
      repo.root.update_attribute(:unprotected, true)
      ::Katello::SmartProxySyncHistory.bulk_start(smart_proxy: capsule_content.smart_proxy, repository_ids: [repo.id])
      repo.smart_proxy_sync_histories.where(:smart_proxy_id => capsule_content.smart_proxy.id).update_all(:finished_at => Time.now)

      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :repository_id => repo.id)

      refute_tree_planned(tree, ::Actions::Pulp3::Orchestration::Repository::RefreshRepos)
      refute_tree_planned(tree, ::Actions::Pulp3::CapsuleContent::Sync)
      refute_tree_planned(tree, ::Actions::Pulp3::CapsuleContent::GenerateMetadata)
      refute_tree_planned(tree, Actions::Pulp3::CapsuleContent::RefreshDistribution)
      refute_tree_planned(tree, Actions::Pulp3::CapsuleContent::RefreshAllDistributions)
    end

    it 'plans correctly for a pulp3 docker repo' do
      with_pulp3_features(capsule_content.smart_proxy)
      capsule_content.smart_proxy.add_lifecycle_environment(environment)
      repo = katello_repositories(:pulp3_docker_1)
      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :repository_id => repo.id)
      assert_tree_planned_steps(tree, ::Actions::Pulp3::ContentGuard::Refresh)
      assert_tree_planned_with(tree, ::Actions::Pulp3::CapsuleContent::Sync) do |input|
        assert_equal capsule_content.smart_proxy.id, input[:smart_proxy_id]
        assert_equal repo.id, input[:repository_id]
      end

      assert_refresh_boundary(tree, [repo.id])
    end

    it 'plans correctly for a pulp3 ansible collection repo' do
      with_pulp3_features(capsule_content.smart_proxy)
      capsule_content.smart_proxy.add_lifecycle_environment(environment)

      repo = katello_repositories(:pulp3_ansible_collection_1)
      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :repository_id => repo.id)
      assert_tree_planned_steps(tree, ::Actions::Pulp3::ContentGuard::Refresh)
      assert_refresh_boundary(tree, [repo.id])
    end

    it 'plans correctly for a pulp3 apt repo' do
      with_pulp3_features(capsule_content.smart_proxy)
      capsule_content.smart_proxy.add_lifecycle_environment(environment)
      repo = katello_repositories(:pulp3_deb_1)
      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :repository_id => repo.id)
      options = { smart_proxy_id: capsule_content.smart_proxy.id,
                  content_view_id: nil,
                  repository_id: repo.id,
                  repository_ids_list: nil,
                  environment_id: nil,
                }

      assert_tree_planned_with(tree, ::Actions::Pulp3::Orchestration::Repository::RefreshRepos, options)

      assert_tree_planned_with(tree, ::Actions::Pulp3::CapsuleContent::Sync) do |input|
        assert_equal capsule_content.smart_proxy.id, input[:smart_proxy_id]
        assert_equal repo.id, input[:repository_id]
      end

      assert_tree_planned_with(tree, ::Actions::Pulp3::CapsuleContent::GenerateMetadata) do |input|
        assert_equal capsule_content.smart_proxy.id, input[:smart_proxy_id]
        assert_equal repo.id, input[:repository_id]
      end

      assert_refresh_boundary(tree, [repo.id])
    end

    it 'plans correctly for a pulp2 apt repo' do
      capsule_content.smart_proxy.add_lifecycle_environment(environment)
      SmartProxy.any_instance.stubs(:pulp3_support?).returns(false)
      repo = katello_repositories(:debian_9_amd64)
      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :repository_id => repo.id)
      options = { smart_proxy_id: capsule_content.smart_proxy.id,
                  content_view_id: nil,
                  repository_id: repo.id,
                  repository_ids_list: nil,
                  environment_id: nil,
                }

      assert_tree_planned_with(tree, ::Actions::Pulp3::Orchestration::Repository::RefreshRepos, options)
      refute_tree_planned(tree, ::Actions::Pulp3::CapsuleContent::RefreshDistribution)
      refute_tree_planned(tree, Actions::Pulp3::CapsuleContent::RefreshAllDistributions)
    end

    it 'plans correctly for a pulp yum repo' do
      capsule_content.smart_proxy.add_lifecycle_environment(environment)
      capsule_content.smart_proxy.features = capsule_content.smart_proxy.features - [Feature.name_map[SmartProxy::PULP3_FEATURE]]
      repo = katello_repositories(:fedora_17_x86_64)
      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :repository_id => repo.id)
      options = { smart_proxy_id: capsule_content.smart_proxy.id,
                  content_view_id: nil,
                  repository_id: repo.id,
                  repository_ids_list: nil,
                  environment_id: nil,
                }

      assert_tree_planned_with(tree, ::Actions::Pulp3::Orchestration::Repository::RefreshRepos, options)
      assert_tree_planned_steps(tree, ::Actions::Pulp3::ContentGuard::Refresh)
    end

    it 'plans correctly for a pulp2 file repo' do
      capsule_content.smart_proxy.add_lifecycle_environment(environment)
      repo = katello_repositories(:generic_file)
      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :repository_id => repo.id)
      options = { smart_proxy_id: capsule_content.smart_proxy.id,
                  content_view_id: nil,
                  repository_id: repo.id,
                  repository_ids_list: nil,
                  environment_id: nil,
                }

      assert_tree_planned_with(tree, ::Actions::Pulp3::Orchestration::Repository::RefreshRepos, options)
    end

    it 'allows limiting scope of the syncing to one environment' do
      SmartProxy.any_instance.stubs(:pulp3_support?).returns(true)
      with_pulp3_features(capsule_content.smart_proxy)
      capsule_content.smart_proxy.add_lifecycle_environment(dev_environment)
      repos_in_dev = Katello::Repository.in_environment(dev_environment).pluck(:pulp_id)
      repo_ids_in_dev = Katello::Repository.in_environment(dev_environment).pluck(:id)

      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :environment_id => dev_environment.id)
      options = { smart_proxy_id: capsule_content.smart_proxy.id,
                  content_view_id: nil,
                  repository_id: nil,
                  repository_ids_list: nil,
                  environment_id: dev_environment.id,
                }
      assert_tree_planned_with(tree, ::Actions::Pulp3::Orchestration::Repository::RefreshRepos, options)

      assert_tree_planned_with(tree, ::Actions::Pulp3::CapsuleContent::Sync) do |input|
        assert_equal capsule_content.smart_proxy.id, input[:smart_proxy_id]
        repo = Katello::Repository.find(input[:repository_id])
        assert_includes repos_in_dev, repo.pulp_id
      end

      assert_tree_planned_with(tree, ::Actions::Pulp3::CapsuleContent::GenerateMetadata) do |input|
        assert_equal capsule_content.smart_proxy.id, input[:smart_proxy_id]
        repo = Katello::Repository.find(input[:repository_id])
        assert_includes repos_in_dev, repo.pulp_id
      end

      assert_refresh_boundary(tree, repo_ids_in_dev)
    end

    def assert_refresh_boundary(tree, expected_repo_ids)
      assert_tree_planned_steps(tree, Actions::Pulp3::CapsuleContent::RefreshAllDistributions)
      planned_repo_ids = []
      assert_tree_planned_with(tree, Actions::Pulp3::CapsuleContent::RefreshDistribution) do |input|
        assert_equal capsule_content.smart_proxy.id, input[:smart_proxy_id]
        planned_repo_ids << input[:repository_id]
      end
      assert_equal expected_repo_ids.uniq.sort, planned_repo_ids.sort
    end

    it 'fails when trying to sync to the default capsule' do
      proxy = SmartProxy.pulp_primary
      proxy.stubs(:pulp_primary?).returns(true)
      action = create_action(action_class)
      action.expects(:action_subject).with(proxy)
      assert_raises(RuntimeError) do
        plan_action(action, proxy)
      end
    end

    it 'fails when trying to sync a lifecyle environment that is not attached' do
      capsule_content.smart_proxy.add_lifecycle_environment(environment)

      action_class.any_instance.expects(:action_subject).with(capsule_content.smart_proxy)

      capsule_content.smart_proxy.lifecycle_environments = []
      action = plan_action_tree(action_class, capsule_content.smart_proxy, :environment_id => staging_environment.id)
      refute_empty action.errors
    end
  end

  class SyncCapsuleTest < TestBase
    let(:action_class) { ::Actions::Katello::CapsuleContent::SyncCapsule }

    it 'routes a replicate()-eligible repo through Replicate, grouped by organization' do
      ::Katello::Pulp3::Replication.stubs(:capable?).returns(true)
      with_pulp3_features(capsule_content.smart_proxy)
      capsule_content.smart_proxy.add_lifecycle_environment(environment)
      repo = katello_repositories(:fedora_17_x86_64)
      repo.root.update_attribute(:unprotected, true)

      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :environment => environment)

      assert_tree_planned_with(tree, ::Actions::Pulp3::CapsuleContent::Replicate) do |input|
        assert_equal capsule_content.smart_proxy.id, input[:smart_proxy_id]
        assert_equal repo.organization.id, input[:organization_id]
      end
      refute_tree_planned(tree, ::Actions::Pulp3::CapsuleContent::Sync)
    end

    it 'keeps a repo on classic sync when the capsule is not replicate()-capable' do
      ::Katello::Pulp3::Replication.stubs(:capable?).returns(false)
      with_pulp3_features(capsule_content.smart_proxy)
      capsule_content.smart_proxy.add_lifecycle_environment(environment)
      repo = katello_repositories(:fedora_17_x86_64)
      repo.root.update_attribute(:unprotected, true)

      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :environment => environment)

      refute_tree_planned(tree, ::Actions::Pulp3::CapsuleContent::Replicate)
      assert_tree_planned_steps(tree, ::Actions::Pulp3::CapsuleContent::Sync)
    end

    it 'keeps a repo on classic sync when the capsule lacks the matching pulp3 plugin' do
      ::Katello::Pulp3::Replication.stubs(:capable?).returns(true)
      with_pulp3_features(capsule_content.smart_proxy)
      capsule_content.smart_proxy.stubs(:capabilities).returns([])
      capsule_content.smart_proxy.add_lifecycle_environment(environment)
      repo = katello_repositories(:fedora_17_x86_64)
      repo.root.update_attribute(:unprotected, true)

      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :environment => environment)

      refute_tree_planned(tree, ::Actions::Pulp3::CapsuleContent::Replicate)
    end

    it 'falls back protected content to classic sync when pulpcore lacks remote transport support' do
      ::Katello::Pulp3::Replication.stubs(:capable?).returns(true)
      ::Katello::Pulp3::Replication.stubs(:protected_replicate_capable?).returns(false)
      with_pulp3_features(capsule_content.smart_proxy)
      capsule_content.smart_proxy.add_lifecycle_environment(environment)
      repo = katello_repositories(:fedora_17_x86_64)
      repo.root.update_attribute(:unprotected, false)

      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :environment => environment)

      refute_tree_planned(tree, ::Actions::Pulp3::CapsuleContent::Replicate)
      assert_tree_planned_steps(tree, ::Actions::Pulp3::CapsuleContent::Sync)
    end

    it 'scopes repository_ids to the capsule\'s full assigned repos and allows pruning for a routine, unscoped capsule sync' do
      ::Katello::Pulp3::Replication.stubs(:capable?).returns(true)
      with_pulp3_features(capsule_content.smart_proxy)
      capsule_content.smart_proxy.add_lifecycle_environment(environment)
      repo = katello_repositories(:fedora_17_x86_64)
      repo.root.update_attribute(:unprotected, true)

      tree = plan_action_tree(action_class, capsule_content.smart_proxy)

      assert_tree_planned_with(tree, ::Actions::Pulp3::CapsuleContent::Replicate) do |input|
        assert_includes input[:repository_ids], repo.id
        assert_equal ::Katello::Pulp3::Replication.effective_remote_download_policy(capsule_content.smart_proxy, repo),
                     input[:remote_download_policy]
        assert input[:prune]
      end
    end

    it 'scopes repository_ids to the requested repository and disallows pruning when the sync is explicitly repo-scoped' do
      ::Katello::Pulp3::Replication.stubs(:capable?).returns(true)
      with_pulp3_features(capsule_content.smart_proxy)
      capsule_content.smart_proxy.add_lifecycle_environment(environment)
      repo = katello_repositories(:fedora_17_x86_64)
      repo.root.update_attribute(:unprotected, true)

      tree = plan_action_tree(action_class, capsule_content.smart_proxy, :repository => repo, :environment => environment)

      assert_tree_planned_with(tree, ::Actions::Pulp3::CapsuleContent::Replicate) do |input|
        assert_equal [repo.id], input[:repository_ids]
        refute input[:prune]
      end
    end

    it 'disables prune for routine syncs when one organization splits across multiple replicate policies' do
      ::Katello::Pulp3::Replication.stubs(:capable?).returns(true)
      with_pulp3_features(capsule_content.smart_proxy)

      repo_one = katello_repositories(:fedora_17_x86_64)
      repo_two = katello_repositories(:fedora_17_x86_64_dev)
      repo_one.root.update_attribute(:unprotected, true)
      repo_two.root.update_attribute(:unprotected, true)

      action_class.any_instance.stubs(:scoped_repositories).returns([repo_one, repo_two])
      ::Katello::Pulp3::Replication.stubs(:replicable_repos_for).returns([[repo_one, repo_two], []])
      ::Katello::Pulp3::Replication.stubs(:group_by_org_and_policy).returns(
        [repo_one.organization, 'immediate'] => [repo_one],
        [repo_one.organization, 'on_demand'] => [repo_two]
      )

      tree = plan_action_tree(action_class, capsule_content.smart_proxy)

      planned_prunes = []
      assert_tree_planned_with(tree, ::Actions::Pulp3::CapsuleContent::Replicate) do |input|
        planned_prunes << input[:prune]
      end

      assert_equal [false, false], planned_prunes.sort
    end

    it 'batches PXE fetch for the replicate path using foreman_proxy_content_batch_size' do
      ::Katello::Pulp3::Replication.stubs(:capable?).returns(true)
      with_pulp3_features(capsule_content.smart_proxy)

      repo_one = katello_repositories(:fedora_17_x86_64)
      repo_two = katello_repositories(:fedora_17_x86_64_dev)
      repo_one.root.update_attribute(:unprotected, true)
      repo_two.root.update_attribute(:unprotected, true)

      action_class.any_instance.stubs(:scoped_repositories).returns([repo_one, repo_two])
      ::Katello::Pulp3::Replication.stubs(:replicable_repos_for).returns([[repo_one, repo_two], []])

      batches = []
      action_class.any_instance.stubs(:plan_pxe_fetch).with do |_smart_proxy, repos|
        batches << Array(repos)
        true
      end

      Setting[:foreman_proxy_content_batch_size] = 1
      plan_action_tree(action_class, capsule_content.smart_proxy)

      assert_equal [1, 1], batches.map(&:size).sort
    end
  end

  class ReplicateTest < TestBase
    let(:action_class) { ::Actions::Pulp3::CapsuleContent::Replicate }
    let(:organization) { get_organization }

    it 'plans with the smart proxy and organization ids' do
      action = plan_action(create_action(action_class), capsule_content.smart_proxy, organization, force_sync: true)
      assert_equal capsule_content.smart_proxy.id, action.input[:smart_proxy_id]
      assert_equal organization.id, action.input[:organization_id]
      assert action.input[:force_sync]
    end

    it 'creates/updates the upstream pulp record and triggers replicate' do
      ::Katello::Pulp3::Replication.expects(:ensure_upstream_pulp!).
        with { |api, org| api.is_a?(::Katello::Pulp3::Api::UpstreamPulp) && api.smart_proxy == capsule_content.smart_proxy && org == organization }.
        returns('/pulp/api/v3/upstream-pulps/abc/')
      ::Katello::Pulp3::Api::UpstreamPulp.any_instance.expects(:replicate).
        with('/pulp/api/v3/upstream-pulps/abc/', replication_request_matching(
          repository_ids: nil, force_sync: false, prune: true, remote_policy: nil,
          protected_base_paths: [], content_guard_href: nil
        )).
        returns(OpenStruct.new(task_group: '/pulp/api/v3/task-groups/123/'))

      action = create_action(action_class)
      plan_action(action, capsule_content.smart_proxy, organization)
      action.invoke_external_task

      assert_equal '/pulp/api/v3/task-groups/123/', action.output[:task_groups].first.href
    end

    it 'forwards repository_ids to replicate when the plan is scoped' do
      ::Katello::Pulp3::Replication.stubs(:ensure_upstream_pulp!).
        returns('/pulp/api/v3/upstream-pulps/abc/')
      ::Katello::Pulp3::Api::UpstreamPulp.any_instance.expects(:replicate).
        with('/pulp/api/v3/upstream-pulps/abc/', replication_request_matching(
          repository_ids: [1], force_sync: false, prune: true, remote_policy: nil,
          protected_base_paths: [], content_guard_href: nil
        )).
        returns(OpenStruct.new(task_group: '/pulp/api/v3/task-groups/123/'))

      action = create_action(action_class)
      plan_action(action, capsule_content.smart_proxy, organization, repository_ids: [1])
      action.invoke_external_task
    end

    it 'forwards prune to replicate' do
      ::Katello::Pulp3::Replication.stubs(:ensure_upstream_pulp!).
        returns('/pulp/api/v3/upstream-pulps/abc/')
      ::Katello::Pulp3::Api::UpstreamPulp.any_instance.expects(:replicate).
        with('/pulp/api/v3/upstream-pulps/abc/', replication_request_matching(
          repository_ids: nil, force_sync: false, prune: false, remote_policy: nil,
          protected_base_paths: [], content_guard_href: nil
        )).
        returns(OpenStruct.new(task_group: '/pulp/api/v3/task-groups/123/'))

      action = create_action(action_class)
      plan_action(action, capsule_content.smart_proxy, organization, prune: false)
      action.invoke_external_task
    end

    it 'forwards policy and protected content guard details to replicate' do
      with_pulp3_features(capsule_content.smart_proxy)
      repo = katello_repositories(:fedora_17_x86_64)
      repo.root.update_attribute(:unprotected, false)
      content_guard = OpenStruct.new(pulp_href: '/pulp/api/v3/contentguards/certguard/rhsm/1/')

      ::Katello::Pulp3::Replication.expects(:ensure_upstream_pulp!).
        with { |_api, org| org == organization }.
        returns('/pulp/api/v3/upstream-pulps/abc/')
      ::Katello::Pulp3::Api::ContentGuard.any_instance.expects(:refresh).returns(content_guard)
      ::Katello::Pulp3::Api::UpstreamPulp.any_instance.expects(:replicate).
        with('/pulp/api/v3/upstream-pulps/abc/', replication_request_matching(
          repository_ids: [repo.id],
          force_sync: false,
          prune: true,
          remote_policy: 'immediate',
          protected_base_paths: [repo.relative_path],
          content_guard_href: content_guard.pulp_href
        )).
        returns(OpenStruct.new(task_group: '/pulp/api/v3/task-groups/123/'))

      action = create_action(action_class)
      plan_action(action, capsule_content.smart_proxy, organization,
                  repository_ids: [repo.id], remote_download_policy: 'immediate')
      action.invoke_external_task
    end

    private

    def replication_request_matching(expected_payload)
      satisfies do |request|
        request.is_a?(::Katello::Pulp3::Replication::Request) &&
          request.to_h == expected_payload
      end
    end
  end
end
