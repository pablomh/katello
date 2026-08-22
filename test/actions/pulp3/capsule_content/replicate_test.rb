require 'katello_test_helper'

module ::Actions::Pulp3::CapsuleContent
  class ReplicateTest < ActiveSupport::TestCase
    include Dynflow::Testing
    include Support::Actions::Fixtures
    include Support::CapsuleSupport

    let(:action_class) { ::Actions::Pulp3::CapsuleContent::Replicate }
    let(:repo) { katello_repositories(:fedora_17_x86_64) }

    def setup
      set_user
    end

    def test_rescue_strategy_is_skip
      action = create_action(action_class)
      assert_equal Dynflow::Action::Rescue::Skip, action.rescue_strategy_for_self
    end

    def test_payload_splits_api_cert_from_ueber_and_keeps_labeled_policy
      proxy = capsule_content.smart_proxy
      action = create_action(action_class)
      plan_action(action, proxy, :organization => repo.root.organization, :repository_ids => [repo.id])
      stub_replicate_certs(action, ueber_cert: "UEBER_CERT")
      ::Katello::Pulp3::Replication.stubs(:remote_download_policy).returns("on_demand")

      expectation = ::Katello::Pulp3::Replication::ProxyClient.any_instance.expects(:replicate)
      expectation.with do |payload|
        payload[:upstream_name] == "katello-satellite-#{repo.root.organization.label}" &&
          payload[:client_cert] == "API_CERT" &&
          payload[:remote_client_cert] == "UEBER_CERT" &&
          payload[:remote_download_policy] == "on_demand" &&
          payload[:policy] == "labeled" &&
          payload[:force_sync] == false &&
          payload[:remote_settings][:policy].nil?
      end
      expectation.returns("task_group" => "/pulp/api/v3/task-groups/1/")

      result = action.invoke_external_task
      assert_equal "/pulp/api/v3/task-groups/1/", result.first["task_group"]
    end

    def test_scoped_replicate_forces_sync
      proxy = capsule_content.smart_proxy
      action = create_action(action_class)
      plan_action(action, proxy, :organization => repo.root.organization, :repository_ids => [repo.id],
                                  :q_select => "pulp_label_select='katello_repo_id=#{repo.id}'")
      stub_replicate_certs(action)

      expectation = ::Katello::Pulp3::Replication::ProxyClient.any_instance.expects(:replicate)
      expectation.with do |payload|
        payload[:force_sync] == true && payload[:q_select].include?('katello_repo_id')
      end
      expectation.returns("task_group" => "/pulp/api/v3/task-groups/1/")

      action.invoke_external_task
    end

    def test_rejects_repository_outside_planned_organization
      proxy = capsule_content.smart_proxy
      action = create_action(action_class)
      plan_action(action, proxy, :organization => repo.root.organization, :repository_ids => [repo.id])
      other_org_repo = stub('other_org_repo', :root => stub('root', :organization_id => repo.root.organization_id + 1))
      action.stubs(:repos).returns([other_org_repo])
      assert_raises(RuntimeError) { action.invoke_external_task }
    end

    def test_inherit_uses_unanimous_repo_download_policy
      proxy = capsule_content.smart_proxy
      proxy.stubs(:download_policy).returns(::SmartProxy::DOWNLOAD_INHERIT)
      action = create_action(action_class)
      plan_action(action, proxy, :organization => repo.root.organization, :repository_ids => [repo.id])
      action.stubs(:smart_proxy).returns(proxy)
      stub_replicate_certs(action)

      expectation = ::Katello::Pulp3::Replication::ProxyClient.any_instance.expects(:replicate)
      expectation.with do |payload|
        payload[:remote_download_policy] == repo.root.download_policy
      end
      expectation.returns("task_group" => "/pulp/api/v3/task-groups/1/")

      action.invoke_external_task
    end

    private

    def stub_replicate_certs(action, ueber_cert: "UEBER_CERT")
      action.stubs(:api_client_cert).returns("API_CERT")
      action.stubs(:api_client_key).returns("API_KEY")
      ::Katello::Pulp3::Replication.stubs(:remote_credentials_for).returns(
        :remote_client_cert => ueber_cert, :remote_client_key => "UEBER_KEY"
      )
      ::Cert::Certs.stubs(:ca_cert).returns("CA")
      ::Katello::Pulp3::Replication.stubs(:satellite_pulp_base_url).returns("https://satellite.example.com")
    end
  end
end
