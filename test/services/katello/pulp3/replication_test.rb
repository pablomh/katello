require 'katello_test_helper'

module Katello
  module Pulp3
    class ReplicationTest < ActiveSupport::TestCase
      include Support::CapsuleSupport

      def setup
        @proxy = proxy_with_pulp
        @yum = katello_repositories(:fedora_17_x86_64)
        @file = katello_repositories(:pulp3_file_1)
        @docker = katello_repositories(:pulp3_docker_1)
      end

      def teardown
        Setting[:pulp_replicate_capsule_sync] = false
        if @proxy.instance_variable_defined?(:@_katello_pulpcore_version)
          @proxy.remove_instance_variable(:@_katello_pulpcore_version)
        end
      end

      def test_flag_default_not_capable
        refute Replication.capable?(@proxy)
      end

      def test_capable_requires_flag_version_and_proxy_action
        Setting[:pulp_replicate_capsule_sync] = true
        @proxy.stubs(:ping_pulp3).returns('versions' => [{ 'component' => 'core', 'version' => '3.113.0' }])
        @proxy.stubs(:has_feature?).with(SmartProxy::PULP3_FEATURE).returns(true)
        @proxy.stubs(:has_feature?).with(Replication::PROXY_FEATURE).returns(true)
        assert Replication.capable?(@proxy)
      end

      def test_not_capable_on_old_pulpcore
        Setting[:pulp_replicate_capsule_sync] = true
        @proxy.stubs(:ping_pulp3).returns('versions' => [{ 'component' => 'core', 'version' => '3.63.0' }])
        @proxy.stubs(:has_feature?).with(SmartProxy::PULP3_FEATURE).returns(true)
        @proxy.stubs(:has_feature?).with(Replication::PROXY_FEATURE).returns(true)
        refute Replication.capable?(@proxy)
      end

      def test_not_capable_without_proxy_feature
        Setting[:pulp_replicate_capsule_sync] = true
        @proxy.stubs(:ping_pulp3).returns('versions' => [{ 'component' => 'core', 'version' => '3.113.0' }])
        @proxy.stubs(:has_feature?).with(SmartProxy::PULP3_FEATURE).returns(true)
        @proxy.stubs(:has_feature?).with(Replication::PROXY_FEATURE).returns(false)
        @proxy.stubs(:capabilities).with(SmartProxy::PULP3_FEATURE).returns(['core', 'rpm'])
        @proxy.stubs(:self_or_colocated_with_feature).with(Replication::PROXY_FEATURE).returns(nil)
        refute Replication.capable?(@proxy)
      end

      def test_capable_via_colocated_foreman_proxy
        Setting[:pulp_replicate_capsule_sync] = true
        companion = mock('foreman_proxy')
        @proxy.stubs(:ping_pulp3).returns('versions' => [{ 'component' => 'core', 'version' => '3.113.0' }])
        @proxy.stubs(:has_feature?).with(SmartProxy::PULP3_FEATURE).returns(true)
        @proxy.stubs(:has_feature?).with(Replication::PROXY_FEATURE).returns(false)
        @proxy.stubs(:capabilities).with(SmartProxy::PULP3_FEATURE).returns(['core', 'rpm'])
        @proxy.stubs(:self_or_colocated_with_feature).with(Replication::PROXY_FEATURE).returns(companion)
        assert Replication.capable?(@proxy)
      end

      def test_not_capable_with_only_pulpcore_capability
        Setting[:pulp_replicate_capsule_sync] = true
        @proxy.stubs(:name).returns('capsule-b-1-pulp')
        @proxy.stubs(:ping_pulp3).returns('versions' => [{ 'component' => 'pulpcore', 'version' => '3.113.1' }])
        @proxy.stubs(:has_feature?).with(SmartProxy::PULP3_FEATURE).returns(true)
        @proxy.stubs(:has_feature?).with(Replication::PROXY_FEATURE).returns(false)
        @proxy.stubs(:capabilities).with(SmartProxy::PULP3_FEATURE).returns(['core', 'replicate'])
        @proxy.stubs(:self_or_colocated_with_feature).with(Replication::PROXY_FEATURE).returns(nil)
        refute Replication.capable?(@proxy)
      end

      def test_pulpcore_version_is_memoized
        Setting[:pulp_replicate_capsule_sync] = true
        @proxy.expects(:ping_pulp3).once.returns('versions' => [{ 'component' => 'core', 'version' => '3.113.0' }])
        @proxy.stubs(:has_feature?).with(SmartProxy::PULP3_FEATURE).returns(true)
        @proxy.stubs(:has_feature?).with(Replication::PROXY_FEATURE).returns(true)
        assert Replication.capable?(@proxy)
        assert Replication.capable?(@proxy)
      end

      def test_foreman_proxy_for_uses_colocated_companion
        companion = mock('foreman_proxy')
        @proxy.stubs(:has_feature?).with(Replication::PROXY_FEATURE).returns(false)
        @proxy.stubs(:self_or_colocated_with_feature).with(Replication::PROXY_FEATURE).returns(companion)
        assert_equal companion, Replication.foreman_proxy_for(@proxy)
      end

      def test_foreman_proxy_for_raises_without_plugin
        @proxy.stubs(:name).returns('capsule-b-1-pulp')
        @proxy.stubs(:has_feature?).with(Replication::PROXY_FEATURE).returns(false)
        @proxy.stubs(:self_or_colocated_with_feature).with(Replication::PROXY_FEATURE).returns(nil)
        assert_raises(RuntimeError) { Replication.foreman_proxy_for(@proxy) }
      end

      def test_partition_yum_and_docker
        replicable, fallback = Replication.partition([@yum, @file, @docker])
        assert_equal [@yum, @docker].map(&:id).sort, replicable.map(&:id).sort
        assert_equal [@file.id], fallback.map(&:id)
      end

      def test_partition_keeps_multi_org_repos_replicable
        other = stub('other_yum', :content_type => 'yum', :root => stub('root', :organization_id => @yum.root.organization_id + 1))
        replicable, fallback = Replication.partition([@yum, other, @file])
        assert_equal [@yum, other].sort_by(&:object_id).map(&:content_type), replicable.map(&:content_type)
        assert_equal [@file], fallback
      end

      def test_distribution_path_for_docker_uses_container_name
        assert_equal @docker.container_repository_name, Replication.distribution_path_for(@docker)
        assert_equal @yum.relative_path.sub(%r{^/}, ''), Replication.distribution_path_for(@yum)
      end

      def test_group_by_org_groups_repos_by_organization
        groups = Replication.group_by_org([@yum, @docker, @file]).to_h { |org, repos| [org.id, repos] }
        assert_equal [@yum, @file].sort_by(&:id), groups[@yum.root.organization_id].sort_by(&:id)
        assert_equal [@docker], groups[@docker.root.organization_id] if @docker.root.organization_id != @yum.root.organization_id
      end

      def test_upstream_name_for_includes_org_label
        org = @yum.root.organization
        assert_equal "katello-satellite-#{org.label}", Replication.upstream_name_for(org)
      end

      def test_assert_single_content_org_rejects_multiple
        repo_a = stub('repo_a', :root => stub('root_a', :organization => stub('org_a', :id => 1)))
        repo_b = stub('repo_b', :root => stub('root_b', :organization => stub('org_b', :id => 2)))
        assert_raises(RuntimeError) { Replication.assert_single_content_org!([repo_a, repo_b]) }
      end

      def test_assert_single_content_org_rejects_mismatch_with_expected_org
        repo = stub('repo', :root => stub('root', :organization => stub('org', :id => 1)))
        organization = stub('org', :id => 2, :name => 'Other')
        assert_raises(RuntimeError) { Replication.assert_single_content_org!([repo], organization) }
      end

      def test_assert_single_content_org_accepts_matching_expected_org
        repo = stub('repo', :root => stub('root', :organization => stub('org', :id => 1)))
        organization = stub('org', :id => 1, :name => 'Match')
        Replication.assert_single_content_org!([repo], organization)
      end

      def test_assert_single_content_org_uses_repository_organization
        organization = stub('org', :id => 1)
        repo = stub('repo', :organization => organization, :root => stub('root'))
        Replication.assert_single_content_org!([repo], organization)
      end

      def test_remote_download_policy_inherit_unanimous
        @proxy.stubs(:download_policy).returns(::SmartProxy::DOWNLOAD_INHERIT)
        assert_equal @yum.root.download_policy, Replication.remote_download_policy(@proxy, [@yum])
      end
    end
  end
end
