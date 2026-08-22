require 'katello_test_helper'

module ::Actions::Pulp3::CapsuleContent
  class RefreshDistributionTest < ActiveSupport::TestCase
    include Dynflow::Testing
    include Support::Actions::Fixtures

    let(:action_class) { ::Actions::Pulp3::CapsuleContent::RefreshDistribution }
    let(:repo) { katello_repositories(:fedora_17_x86_64) }
    let(:proxy) { SmartProxy.pulp_primary }

    def setup
      set_user
    end

    def test_plans_contents_changed_option
      action = create_action(action_class)
      plan_action(action, repo, proxy, :contents_changed => false)
      refute action.input[:options][:contents_changed]
    end

    def test_retries_uniqueness_conflict_once
      action = create_action(action_class)
      plan_action(action, repo, proxy)
      adapter = mock('mirror_adapter')
      race = sequence('race')
      adapter.expects(:refresh_distributions).raises(StandardError, %({"base_path":["This field must be unique."]})).in_sequence(race)
      adapter.expects(:refresh_distributions).returns(['ok']).in_sequence(race)
      action.stubs(:repo).returns(stub('repo', :backend_service => stub('backend', :with_mirror_adapter => adapter)))

      assert_equal ['ok'], action.invoke_external_task
    end

    def test_does_not_retry_unrelated_errors
      action = create_action(action_class)
      plan_action(action, repo, proxy)
      adapter = mock('mirror_adapter')
      adapter.expects(:refresh_distributions).raises(StandardError, 'publication is missing')
      action.stubs(:repo).returns(stub('repo', :backend_service => stub('backend', :with_mirror_adapter => adapter)))

      assert_raises(StandardError) { action.invoke_external_task }
    end
  end

  class GenerateMetadataTest < ActiveSupport::TestCase
    include Dynflow::Testing
    include Support::Actions::Fixtures

    let(:action_class) { ::Actions::Pulp3::CapsuleContent::GenerateMetadata }
    let(:repo) { katello_repositories(:fedora_17_x86_64) }
    let(:proxy) { SmartProxy.pulp_primary }

    def setup
      set_user
    end

    def test_plans_refresh_distribution_with_contents_changed
      action = create_action(action_class)
      plan_action(action, repo, proxy, :contents_changed => true)
      assert_action_planned_with action, ::Actions::Pulp3::CapsuleContent::RefreshDistribution,
                                 repo, proxy, :contents_changed => true
    end
  end
end
