require 'katello_test_helper'

module ::Actions::Pulp3::CapsuleContent
  class GenerateMetadataTest < ActiveSupport::TestCase
    include Dynflow::Testing
    include Support::Actions::Fixtures
    include Support::CapsuleSupport
    include Support::Actions::RemoteAction

    let(:proxy) { capsule_content.smart_proxy }

    before do
      set_user
      SmartProxy.any_instance.stubs(:ping_pulp3).returns({})
      SmartProxy.any_instance.stubs(:pulp3_configuration).returns(nil)
    end

    it 'does not plan RefreshDistribution inline for publication-less repos (e.g. docker)' do
      repo = katello_repositories(:pulp3_docker_1)
      tree = plan_action_tree(::Actions::Pulp3::CapsuleContent::GenerateMetadata,
                              repo, proxy)

      refute_tree_planned(tree, ::Actions::Pulp3::CapsuleContent::RefreshDistribution)
    end

    it 'does not plan RefreshDistribution inline for publication-based repos (e.g. file)' do
      repo = katello_repositories(:pulp3_file_1)
      tree = plan_action_tree(::Actions::Pulp3::CapsuleContent::GenerateMetadata,
                              repo, proxy)

      refute_tree_planned(tree, ::Actions::Pulp3::CapsuleContent::RefreshDistribution)
    end
  end

  class RefreshAllDistributionsTest < ActiveSupport::TestCase
    include Dynflow::Testing
    include Support::Actions::Fixtures
    include Support::CapsuleSupport

    let(:action_class) { ::Actions::Pulp3::CapsuleContent::RefreshAllDistributions }

    def setup
      set_user
    end

    def test_plans_refresh_for_each_repo
      proxy = capsule_content.smart_proxy
      yum = katello_repositories(:fedora_17_x86_64)
      file = katello_repositories(:pulp3_file_1)
      action = create_action(action_class)
      plan_action(action, proxy, [yum, file])

      assert_action_planned_with action, ::Actions::Pulp3::CapsuleContent::RefreshDistribution, yum, proxy
      assert_action_planned_with action, ::Actions::Pulp3::CapsuleContent::RefreshDistribution, file, proxy
    end

    def test_batches_refresh_planning_by_setting
      proxy = capsule_content.smart_proxy
      yum = katello_repositories(:fedora_17_x86_64)
      file = katello_repositories(:pulp3_file_1)
      action = create_action(action_class)
      original_batch_size = Setting[:foreman_proxy_content_batch_size]
      Setting[:foreman_proxy_content_batch_size] = 1

      action.expects(:concurrence).yields.ordered
      action.expects(:plan_action).with(::Actions::Pulp3::CapsuleContent::RefreshDistribution, yum, proxy).ordered
      action.expects(:concurrence).yields.ordered
      action.expects(:plan_action).with(::Actions::Pulp3::CapsuleContent::RefreshDistribution, file, proxy).ordered

      plan_action(action, proxy, [yum, file])
    ensure
      Setting[:foreman_proxy_content_batch_size] = original_batch_size
    end

    def test_empty_list_is_a_noop
      proxy = capsule_content.smart_proxy
      action = create_action(action_class)
      plan_action(action, proxy, [])
      refute_action_planned action, ::Actions::Pulp3::CapsuleContent::RefreshDistribution
    end
  end
end
