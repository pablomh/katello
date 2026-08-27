require 'katello_test_helper'

module ::Actions::Pulp3::CapsuleContent
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
end
