require 'katello_test_helper'

module ::Actions::Pulp3::CapsuleContent
  class DistributionConflictTest < ActiveSupport::TestCase
    it 'matches both async task and direct api race messages' do
      async_error = ::Katello::Errors::Pulp3Error.new(
        "{'base_path': [ErrorDetail(string='This field must be unique.', code='unique')]}"
      )
      api_error = RuntimeError.new('{"base_path":["Overlaps with existing distribution"]}')

      assert ::Katello::Pulp3::DistributionConflict.create_race?(async_error)
      assert ::Katello::Pulp3::DistributionConflict.create_race?(api_error)
      refute ::Katello::Pulp3::DistributionConflict.create_race?("Remote artifacts cannot be exported")
    end

    it 'matches an overlap message with no base_path field name at all' do
      # The real overlap error is not always nested under a "base_path" key.
      assert ::Katello::Pulp3::DistributionConflict.create_race?("Overlaps with existing distribution.")
      assert ::Katello::Pulp3::DistributionConflict.create_race?("base_path: [\"Overlaps with existing distribution.\"]")
    end
  end

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

  class RefreshDistributionTest < ActiveSupport::TestCase
    include Dynflow::Testing
    include Support::Actions::Fixtures
    include Support::CapsuleSupport
    include Support::Actions::RemoteAction

    let(:proxy) { capsule_content.smart_proxy }
    let(:repo) { katello_repositories(:pulp3_docker_1) }

    before do
      set_user
      SmartProxy.any_instance.stubs(:ping_pulp3).returns({})
      SmartProxy.any_instance.stubs(:pulp3_configuration).returns(nil)
    end

    def build_action
      action = create_action(::Actions::Pulp3::CapsuleContent::RefreshDistribution)
      action.stubs(:input).returns('repository_id' => repo.id, 'smart_proxy_id' => proxy.id)
      action
    end

    def stub_mirror_adapter(action, adapter)
      action.stubs(:repo).returns(stub('repo', :backend_service => stub('backend', :with_mirror_adapter => adapter)))
    end

    it 'retries once when the concurrent create races on base_path' do
      action = build_action
      adapter = mock('mirror_adapter')
      race = sequence('race')
      adapter.expects(:refresh_distributions).raises(
        ::Katello::Errors::Pulp3Error.new("{'base_path': [ErrorDetail(string='This field must be unique.', code='unique')]}")
      ).in_sequence(race)
      adapter.expects(:refresh_distributions).returns(['ok']).in_sequence(race)
      stub_mirror_adapter(action, adapter)

      assert_equal ['ok'], action.invoke_external_task
    end

    it 're-raises after the one allowed retry is exhausted' do
      action = build_action
      adapter = mock('mirror_adapter')
      error = ::Katello::Errors::Pulp3Error.new("{'base_path': ['Overlaps with existing distribution']}")
      adapter.expects(:refresh_distributions).twice.raises(error)
      stub_mirror_adapter(action, adapter)

      assert_raises(::Katello::Errors::Pulp3Error) { action.invoke_external_task }
    end

    it 'does not retry unrelated errors' do
      action = build_action
      adapter = mock('mirror_adapter')
      adapter.expects(:refresh_distributions).once.raises(::Katello::Errors::Pulp3Error.new("Remote artifacts cannot be exported"))
      stub_mirror_adapter(action, adapter)

      assert_raises(::Katello::Errors::Pulp3Error) { action.invoke_external_task }
    end

    it 'retries once when a dispatched task fails on the race instead of erroring immediately' do
      action = build_action
      mock_task = mock('pulp_task')
      action.expects(:invoke_external_task).returns(mock_task)
      action.expects(:external_task=).with(mock_task)

      error = ::Katello::Errors::Pulp3Error.new("{'base_path': [ErrorDetail(string='This field must be unique.', code='unique')]}")
      action.rescue_external_task(error)
      assert action.output[:retried_distribution_refresh]
    end

    it 'does not retry a dispatched task failure twice' do
      action = build_action
      action.output[:retried_distribution_refresh] = true
      action.expects(:invoke_external_task).never

      error = ::Katello::Errors::Pulp3Error.new("{'base_path': ['Overlaps with existing distribution']}")
      assert_raises(::Katello::Errors::Pulp3Error) { action.rescue_external_task(error) }
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

    def test_empty_list_is_a_noop
      proxy = capsule_content.smart_proxy
      action = create_action(action_class)
      plan_action(action, proxy, [])
      refute_action_planned action, ::Actions::Pulp3::CapsuleContent::RefreshDistribution
    end
  end
end
