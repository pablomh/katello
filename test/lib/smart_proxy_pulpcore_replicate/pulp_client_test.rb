require 'katello_test_helper'
require 'json'
require 'cgi'
require_relative '../../../lib/smart_proxy_pulpcore_replicate/pulp_client'

module Proxy
  module PulpcoreReplicate
    class PulpClientTest < ActiveSupport::TestCase
      UPSTREAM_HREF = '/pulp/api/v3/upstream-pulps/01a0263b-0070-7c00-ba63-72cd2a35bf05/'.freeze
      UPSTREAM_PK = '01a0263b-0070-7c00-ba63-72cd2a35bf05'.freeze
      CLIENT_SOURCE = File.expand_path('../../../lib/smart_proxy_pulpcore_replicate/pulp_client.rb', __dir__)

      # Match Sinatra JSON.parse on Foreman Proxy: string keys, no ActiveSupport.
      def wire(payload)
        JSON.parse(JSON.generate(payload))
      end

      def server(href, labels = {})
        { 'pulp_href' => href, 'pulp_labels' => labels }
      end

      def test_plugin_source_does_not_use_activesupport_hash_api
        source = File.read(CLIENT_SOURCE)
        refute_match(/\.with_indifferent_access/, source)
        refute_includes source, 'def indifferent'
        refute_match(/payload\[:/, source)
      end

      def test_upstream_pk_from_detail_href
        href = "/pulp/api/v3/upstream-pulps/01a0263b-0070-7c00-ba63-72cd2a35bf05/"
        assert_equal "01a0263b-0070-7c00-ba63-72cd2a35bf05", PulpClient.upstream_pk(href)
      end

      def test_upstream_pk_from_prn
        prn = "prn:core.upstreampulp:01a0263b-0070-7c00-ba63-72cd2a35bf05"
        assert_equal "01a0263b-0070-7c00-ba63-72cd2a35bf05", PulpClient.upstream_pk(prn)
      end

      def test_upstream_pk_rejects_collection_href
        assert_raises(ArgumentError) do
          PulpClient.upstream_pk("/pulp/api/v3/upstream-pulps/")
        end
      end

      def test_attr_drift_patches_api_root_and_certs_only_when_changed
        existing = {
          'api_root' => 'pulp',
          'policy' => 'labeled',
          'client_cert' => 'OLD',
          'q_select' => 'le=Library',
        }
        attrs = {
          'name' => 'katello-satellite',
          'api_root' => '/pulp/',
          'policy' => 'labeled',
          'client_cert' => 'NEW',
          'q_select' => 'le=Library',
        }
        drift = PulpClient.attr_drift(existing, attrs)
        assert_equal '/pulp/', drift['api_root']
        assert_equal 'NEW', drift['client_cert']
        refute_includes drift.keys, 'policy'
        refute_includes drift.keys, 'q_select'
        refute_includes drift.keys, 'name'
      end

      def test_attr_drift_empty_when_in_sync
        existing = { 'api_root' => '/pulp/', 'policy' => 'labeled' }
        attrs = { 'api_root' => '/pulp/', 'policy' => 'labeled' }
        assert_empty PulpClient.attr_drift(existing, attrs)
      end

      def test_attr_drift_ignores_redacted_secrets
        existing = { 'api_root' => '/pulp/', 'client_key' => nil }
        attrs = { 'api_root' => '/pulp/', 'client_key' => 'PRIVATE' }
        assert_empty PulpClient.attr_drift(existing, attrs)
      end

      def test_attr_drift_stringifies_symbol_keys
        existing = { api_root: '/pulp/' }
        attrs = { 'api_root' => '/other/' }
        drift = PulpClient.attr_drift(existing, attrs)
        assert_equal '/other/', drift['api_root']
      end

      def test_force_sync_labels_preserve_existing
        labels = PulpClient.force_sync_labels({ 'UpstreamPulp' => 'pk' }, '2026-08-22T00:00:00Z')
        assert_equal 'pk', labels['UpstreamPulp']
        assert_equal '2026-08-22T00:00:00Z', labels[PulpClient::FORCE_SYNC_LABEL]
      end

      def test_http_error_not_found
        assert HttpError.new(404, 'missing').not_found?
        refute HttpError.new(500, 'boom').not_found?
      end

      def test_create_or_get_filters_by_name
        client = PulpClient.new(pulp_url: 'https://pulp.example.com')
        client.expects(:get).with("/pulp/api/v3/upstream-pulps/?name=#{CGI.escape(PulpClient::DEFAULT_UPSTREAM_NAME)}").returns('results' => [])
        client.expects(:post).with("/pulp/api/v3/upstream-pulps/", has_entries('name' => PulpClient::DEFAULT_UPSTREAM_NAME, 'base_url' => 'https://sat.example.com')).returns('pulp_href' => UPSTREAM_HREF)
        result = client.create_or_get_upstream_pulp(wire('satellite_base_url' => 'https://sat.example.com', 'policy' => 'labeled'))
        assert_equal UPSTREAM_HREF, result['pulp_href']
      end

      def test_create_or_get_uses_payload_upstream_name
        client = PulpClient.new
        client.expects(:get).with("/pulp/api/v3/upstream-pulps/?name=#{CGI.escape('katello-satellite-acme')}").returns('results' => [])
        client.expects(:post).with("/pulp/api/v3/upstream-pulps/", has_entries('name' => 'katello-satellite-acme')).returns('pulp_href' => UPSTREAM_HREF)
        client.create_or_get_upstream_pulp(wire('upstream_name' => 'katello-satellite-acme', 'satellite_base_url' => 'https://sat.example.com'))
      end

      def test_create_or_get_recovers_from_concurrent_create
        client = PulpClient.new
        winner = { 'name' => 'katello-satellite-acme', 'pulp_href' => UPSTREAM_HREF, 'base_url' => 'https://sat.example.com',
                   'api_root' => '/pulp/', 'policy' => 'labeled', 'tls_validation' => true }
        client.stubs(:get).with("/pulp/api/v3/upstream-pulps/?name=#{CGI.escape('katello-satellite-acme')}").returns(
          { 'results' => [] }, { 'results' => [winner] }
        )
        client.expects(:post).raises(HttpError.new(400, %({"name": ["This field must be unique."]})))
        client.expects(:patch).never

        result = client.create_or_get_upstream_pulp(wire('upstream_name' => 'katello-satellite-acme', 'satellite_base_url' => 'https://sat.example.com'))
        assert_equal UPSTREAM_HREF, result['pulp_href']
      end

      def test_create_or_get_accepts_symbol_payload_keys
        client = PulpClient.new
        client.stubs(:list_upstream_pulps).returns([])
        client.expects(:post).with("/pulp/api/v3/upstream-pulps/", has_entries('base_url' => 'https://sat.example.com')).returns('pulp_href' => UPSTREAM_HREF)
        client.create_or_get_upstream_pulp(satellite_base_url: 'https://sat.example.com')
      end

      def test_stamp_unlabeled_only_rpm_and_container
        client = PulpClient.new
        client.expects(:list_distributions).with('rpm', ['p']).returns([])
        client.expects(:list_distributions).with('container', ['p']).returns([])
        client.stubs(:mark_adopted)
        client.send(:stamp_unlabeled, server(UPSTREAM_HREF), wire('adopt_base_paths' => ['p']))
      end

      def test_stamp_unlabeled_skips_already_labeled
        client = PulpClient.new
        labeled = {
          'pulp_href' => '/pulp/api/v3/distributions/rpm/rpm/1/',
          'name' => 'already',
          'base_path' => 'path-a',
          'pulp_labels' => { 'UpstreamPulp' => UPSTREAM_PK },
        }
        unlabeled = {
          'pulp_href' => '/pulp/api/v3/distributions/rpm/rpm/2/',
          'name' => 'new',
          'base_path' => 'path-b',
          'pulp_labels' => {},
        }
        client.stubs(:list_distributions).with('rpm', ['path-a', 'path-b']).returns([labeled, unlabeled])
        client.stubs(:list_distributions).with('container', ['path-a', 'path-b']).returns([])
        client.expects(:merge_labels).with('/pulp/api/v3/distributions/rpm/rpm/2/', {}, { 'UpstreamPulp' => UPSTREAM_PK })
        client.expects(:stamp_remotes_and_repos).once
        client.stubs(:mark_adopted)
        client.send(:stamp_unlabeled, server(UPSTREAM_HREF), wire('adopt_base_paths' => ['path-a', 'path-b']))
      end

      def test_stamp_unlabeled_reads_json_string_keys
        client = PulpClient.new
        client.expects(:list_distributions).with('rpm', ['p']).returns([])
        client.expects(:list_distributions).with('container', ['p']).returns([])
        client.stubs(:mark_adopted)
        client.send(:stamp_unlabeled, server(UPSTREAM_HREF), JSON.parse('{"adopt_base_paths":["p"]}'))
      end

      def test_stamp_unlabeled_ignores_missing_plugin
        client = PulpClient.new
        client.stubs(:list_distributions).raises(HttpError.new(404, 'nope'))
        client.stubs(:mark_adopted)
        assert_nothing_raised do
          client.send(:stamp_unlabeled, server(UPSTREAM_HREF), wire('adopt_base_paths' => ['p']))
        end
      end

      def test_stamp_unlabeled_reraises_non_404
        client = PulpClient.new
        client.stubs(:list_distributions).raises(HttpError.new(500, 'boom'))
        assert_raises(HttpError) do
          client.send(:stamp_unlabeled, server(UPSTREAM_HREF), wire('adopt_base_paths' => ['p']))
        end
      end

      def test_replicate_skips_stamping_when_already_reconciled
        client = PulpClient.new
        reconciled_server = server(UPSTREAM_HREF, { 'katello_adopted' => 'true' })
        client.stubs(:create_or_get_upstream_pulp).returns(reconciled_server)
        client.expects(:stamp_unlabeled).never
        client.stubs(:post).returns({})
        client.replicate(wire('adopt_base_paths' => ['p']))
      end

      def test_force_sync_uses_flag_only
        client = PulpClient.new
        assert client.send(:force_sync?, wire('force_sync' => true))
        refute client.send(:force_sync?, wire('force_sync' => false, 'last_replication' => nil))
      end

      def test_upstream_attrs_from_json_payload
        client = PulpClient.new
        attrs = client.send(:upstream_attrs, wire(
          'satellite_base_url' => 'https://sat.example.com',
          'stored_q_select' => "pulp_label_select='katello_le=Library'",
          'policy' => 'labeled',
          'remote_settings' => {
            'total_timeout' => 3600,
            'rate_limit' => 5000,
          }
        ))
        assert_equal 'https://sat.example.com', attrs['base_url']
        assert_equal '/pulp/', attrs['api_root']
        assert_equal 'labeled', attrs['policy']
        assert_equal "pulp_label_select='katello_le=Library'", attrs['q_select']
        assert_equal 3600, attrs['total_timeout']
        refute_includes attrs.keys, 'rate_limit'
      end

      def test_remote_patch_applies_rate_limit_to_remotes_only
        client = PulpClient.new
        patch = client.send(:remote_patch, wire(
          'remote_download_policy' => 'immediate',
          'remote_settings' => { 'rate_limit' => 5000, 'sock_read_timeout' => 120 }
        ))
        assert_equal 'immediate', patch['policy']
        assert_equal 5000, patch['rate_limit']
        assert_equal 120, patch['sock_read_timeout']
      end
    end
  end
end
