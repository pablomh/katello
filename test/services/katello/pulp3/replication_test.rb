require 'katello_test_helper'

module Katello::Pulp3
  class ReplicationTest < ActiveSupport::TestCase
    include Support::CapsuleSupport

    def setup
      @yum_repo = katello_repositories(:fedora_17_x86_64)
      @docker_repo = katello_repositories(:pulp3_docker_1)
      @file_repo = katello_repositories(:pulp3_file_1)
    end

    it 'treats only yum as replicable, leaving containers and everything else on the classic path' do
      assert ::Katello::Pulp3::Replication.replicable_type?(@yum_repo)
      refute ::Katello::Pulp3::Replication.replicable_type?(@docker_repo)
      refute ::Katello::Pulp3::Replication.replicable_type?(@file_repo)
    end

    it 'partitions docker repos into the classic fallback set' do
      replicable, fallback = ::Katello::Pulp3::Replication.partition([@yum_repo, @docker_repo, @file_repo])
      assert_equal [@yum_repo], replicable
      assert_equal [@docker_repo, @file_repo], fallback
    end

    it 'falls back docker repos even when the capsule is otherwise replicate-capable' do
      Setting[:pulp_replicate_capsule_sync] = true
      smart_proxy = smart_proxies(:four)
      smart_proxy.stubs(:has_feature?).with(::SmartProxy::PULP3_FEATURE).returns(true)
      smart_proxy.stubs(:ping_pulp3).returns(
        'versions' => [{ 'component' => 'core', 'version' => '3.117.0' }]
      )

      replicable, fallback = ::Katello::Pulp3::Replication.replicable_repos_for(
        smart_proxy,
        [@yum_repo, @docker_repo],
        pulp3_support: { @yum_repo => true, @docker_repo => true }
      )

      assert_equal [@yum_repo], replicable
      assert_equal [@docker_repo], fallback
    end

    it 'groups repos by organization, dropping repos with no organization' do
      grouped = ::Katello::Pulp3::Replication.group_by_org([@yum_repo])
      assert_equal [@yum_repo], grouped[@yum_repo.organization]
    end

    it 'groups repos in the same organization into separate buckets when their effective download policy differs' do
      rhel7 = katello_repositories(:rhel_7_x86_64)
      assert_equal @yum_repo.organization, rhel7.organization

      smart_proxies(:four).stubs(:download_policy).returns(::SmartProxy::DOWNLOAD_INHERIT)
      @yum_repo.root.update_attribute(:download_policy, 'immediate')
      rhel7.root.update_attribute(:download_policy, 'on_demand')

      grouped = ::Katello::Pulp3::Replication.group_by_org_and_policy(smart_proxies(:four), [@yum_repo, rhel7])

      assert_equal 2, grouped.size
      assert_equal [@yum_repo], grouped[[@yum_repo.organization, 'immediate']]
      assert_equal [rhel7], grouped[[rhel7.organization, 'on_demand']]
    end

    it 'groups repos in the same organization into one bucket when their effective download policy matches' do
      rhel7 = katello_repositories(:rhel_7_x86_64)
      smart_proxies(:four).stubs(:download_policy).returns('on_demand')

      grouped = ::Katello::Pulp3::Replication.group_by_org_and_policy(smart_proxies(:four), [@yum_repo, rhel7])

      assert_equal 1, grouped.size
      assert_equal [@yum_repo, rhel7], grouped[[@yum_repo.organization, 'on_demand']]
    end

    it 'is not capable when the setting is disabled' do
      Setting[:pulp_replicate_capsule_sync] = false
      refute ::Katello::Pulp3::Replication.capable?(smart_proxies(:four))
    end

    it 'is not capable when the smart proxy lacks the pulp3 feature row' do
      Setting[:pulp_replicate_capsule_sync] = true
      smart_proxies(:four).stubs(:has_feature?).with(::SmartProxy::PULP3_FEATURE).returns(false)
      refute ::Katello::Pulp3::Replication.capable?(smart_proxies(:four))
    end

    it 'is not capable when the reported pulpcore version is too old' do
      Setting[:pulp_replicate_capsule_sync] = true
      smart_proxies(:four).stubs(:has_feature?).with(::SmartProxy::PULP3_FEATURE).returns(true)
      smart_proxies(:four).stubs(:ping_pulp3).returns(
        'versions' => [{ 'component' => 'core', 'version' => '3.100.0' }]
      )
      refute ::Katello::Pulp3::Replication.capable?(smart_proxies(:four))
    end

    it 'is capable when the setting is on and pulpcore is new enough' do
      Setting[:pulp_replicate_capsule_sync] = true
      smart_proxies(:four).stubs(:has_feature?).with(::SmartProxy::PULP3_FEATURE).returns(true)
      smart_proxies(:four).stubs(:ping_pulp3).returns(
        'versions' => [{ 'component' => 'core', 'version' => '3.113.0' }]
      )
      assert ::Katello::Pulp3::Replication.capable?(smart_proxies(:four))
    end

    it 'builds remote transport fields from an already-fetched ueber_cert/ca_cert' do
      ueber_cert = { cert: 'client-cert', key: 'client-key' }
      transport = ::Katello::Pulp3::Replication.remote_transport_for(ueber_cert, 'ca-cert')
      assert_equal 'ca-cert', transport[:remote_ca_cert]
      assert_equal 'client-cert', transport[:remote_client_cert]
      assert_equal 'client-key', transport[:remote_client_key]
      assert transport[:remote_tls_validation]
    end

    it 'keeps upstream api credentials distinct from remote transport credentials' do
      ueber_cert = { cert: 'client-cert', key: 'client-key' }

      assert_equal(
        { client_cert: 'client-cert', client_key: 'client-key' },
        ::Katello::Pulp3::Replication.upstream_api_credentials_for(ueber_cert)
      )
    end

    it 'treats protected yum content as protected, but not containers or unprotected yum' do
      @yum_repo.root.update_attribute(:unprotected, false)
      assert ::Katello::Pulp3::Replication.protected_content?(@yum_repo)
      refute ::Katello::Pulp3::Replication.protected_content?(@docker_repo)

      @yum_repo.root.update_attribute(:unprotected, true)
      refute ::Katello::Pulp3::Replication.protected_content?(@yum_repo)
    end

    it 'is not protected-replicate-capable when pulpcore is below the remote transport minimum' do
      smart_proxies(:four).stubs(:ping_pulp3).returns(
        'versions' => [{ 'component' => 'core', 'version' => '3.113.0' }]
      )
      refute ::Katello::Pulp3::Replication.protected_replicate_capable?(smart_proxies(:four))
    end

    it 'is protected-replicate-capable when pulpcore meets the remote transport minimum' do
      smart_proxies(:four).stubs(:ping_pulp3).returns(
        'versions' => [{ 'component' => 'core', 'version' => '3.117.0' }]
      )
      assert ::Katello::Pulp3::Replication.protected_replicate_capable?(smart_proxies(:four))
    end

    it 'resolves the inherit download policy to the default proxy download policy setting when the repo root has none' do
      Setting[:default_proxy_download_policy] = 'on_demand'
      smart_proxies(:four).stubs(:download_policy).returns(::SmartProxy::DOWNLOAD_INHERIT)
      @yum_repo.root.update_attribute(:download_policy, nil)
      assert_equal 'on_demand', ::Katello::Pulp3::Replication.effective_remote_download_policy(smart_proxies(:four), @yum_repo)
    end

    it 'uses the repository root policy when the capsule inherits download policy' do
      smart_proxies(:four).stubs(:download_policy).returns(::SmartProxy::DOWNLOAD_INHERIT)
      @yum_repo.root.update_attribute(:download_policy, 'streamed')

      assert_equal 'streamed', ::Katello::Pulp3::Replication.effective_remote_download_policy(smart_proxies(:four), @yum_repo)
    end

    it 'builds upstream remote settings from sync tuning settings' do
      Setting[:sync_total_timeout] = 100
      Setting[:sync_connect_timeout_v2] = 20
      Setting[:sync_sock_connect_timeout] = 21
      Setting[:sync_sock_read_timeout] = 22
      Setting[:download_rate_limit] = 23

      assert_equal(
        {
          total_timeout: 100,
          connect_timeout: 20,
          sock_connect_timeout: 21,
          sock_read_timeout: 22,
          rate_limit: 23,
        },
        ::Katello::Pulp3::Replication.upstream_remote_settings
      )
    end

    it 'derives the primary upstream base url and api_root from pulp3_url' do
      proxy = stub
      proxy.stubs(:pulp3_url).returns('https://sat.example.com/pulp/api/v3')
      ::SmartProxy.stubs(:pulp_primary).returns(proxy)

      assert_equal 'https://sat.example.com', ::Katello::Pulp3::Replication.primary_pulp_base_url
      assert_equal '/pulp/', ::Katello::Pulp3::Replication.primary_pulp_api_root
    end

    it 'builds a stable endpoint profile without per-run remote policy' do
      organization = taxonomies(:empty_organization)
      ::Cert::Certs.stubs(:ueber_cert).with(organization).returns(cert: 'client-cert', key: 'client-key')
      ::Cert::Certs.stubs(:ca_cert).returns('ca-cert')
      ::Katello::Pulp3::Replication.stubs(:primary_pulp_base_url).returns('https://sat.example.com')
      ::Katello::Pulp3::Replication.stubs(:primary_pulp_api_root).returns('/pulp/')
      ::Katello::Pulp3::Replication.stubs(:upstream_remote_settings).returns(total_timeout: 30)

      profile = ::Katello::Pulp3::Replication.endpoint_profile_for(organization)

      assert_equal "katello-satellite-#{organization.label}", profile.name
      assert_equal(
        {
          base_url: 'https://sat.example.com',
          api_root: '/pulp/',
          policy: 'labeled',
          client_cert: 'client-cert',
          client_key: 'client-key',
          ca_cert: 'ca-cert',
          tls_validation: true,
          remote_ca_cert: 'ca-cert',
          remote_client_cert: 'client-cert',
          remote_client_key: 'client-key',
          remote_tls_validation: true,
          total_timeout: 30,
        },
        profile.to_h
      )
    end

    it 'builds replication request payloads separately from endpoint configuration' do
      request = ::Katello::Pulp3::Replication::Request.new(
        repository_ids: [1, nil, 2],
        force_sync: true,
        prune: false,
        remote_policy: 'on_demand',
        protected_base_paths: ['path/one', nil],
        content_guard_href: '/pulp/api/v3/contentguards/certguard/rhsm/1/'
      )

      assert_equal(
        {
          repository_ids: [1, 2],
          force_sync: true,
          prune: false,
          remote_policy: 'on_demand',
          protected_base_paths: ['path/one'],
          content_guard_href: '/pulp/api/v3/contentguards/certguard/rhsm/1/',
        },
        request.to_h
      )
    end

    it 'delegates distribution paths to the repository backend service' do
      with_pulp3_features(capsule_content.smart_proxy)
      assert_equal @yum_repo.relative_path,
        ::Katello::Pulp3::Replication.distribution_path_for(capsule_content.smart_proxy, @yum_repo)
      assert_equal @docker_repo.container_repository_name,
        ::Katello::Pulp3::Replication.distribution_path_for(capsule_content.smart_proxy, @docker_repo)
    end

    it 'ensures an upstream pulp endpoint built from the organization profile' do
      organization = taxonomies(:empty_organization)
      api = mock
      matches_organization_profile = lambda do |profile|
        profile.is_a?(::Katello::Pulp3::Replication::EndpointProfile) && profile.organization == organization
      end
      api.expects(:ensure_endpoint).with(&matches_organization_profile).returns('/pulp/api/v3/upstream-pulps/abc/')

      assert_equal '/pulp/api/v3/upstream-pulps/abc/', ::Katello::Pulp3::Replication.ensure_upstream_pulp!(api, organization)
    end

    it 'treats a ping failure as not protected-replicate-capable, without raising' do
      smart_proxies(:four).stubs(:ping_pulp3).raises(StandardError, 'connection refused')
      refute ::Katello::Pulp3::Replication.protected_replicate_capable?(smart_proxies(:four))
    end

    it 'treats a ping failure as not pulpcore-version-ok, without raising' do
      smart_proxies(:four).stubs(:ping_pulp3).raises(StandardError, 'connection refused')
      refute ::Katello::Pulp3::Replication.pulpcore_version_ok?(smart_proxies(:four))
    end

    it 'treats a malformed ping response as not pulpcore-version-ok, without raising' do
      smart_proxies(:four).stubs(:ping_pulp3).returns(nil)
      refute ::Katello::Pulp3::Replication.pulpcore_version_ok?(smart_proxies(:four))
    end
  end
end
