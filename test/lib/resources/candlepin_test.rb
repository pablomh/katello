require 'katello_test_helper'

module Katello
  module Resources
    module Candlepin
      class UpstreamCandlepinResourceTest < ActiveSupport::TestCase
        def teardown
          UpstreamCandlepinResource.reset_connection!
        end

        def test_upstream_consumer_nil_current_organization
          Organization.stubs(:current).returns(nil)
          UpstreamCandlepinResource.upstream_consumer
          flunk("Failed to raise exception when current organization is nil.")
        rescue RuntimeError => e
          assert_equal(e.message, "Current organization not set.", "Invalid message: #{e.message}")
        end

        def test_upstream_consumer_current_organization_no_imported_manifest
          Organization.stubs(:current).returns(stub(owner_details: {}))

          assert_raises(Katello::Errors::NoManifestImported) do
            UpstreamCandlepinResource.upstream_consumer
          end
        end

        def test_global_proxy_nil
          Setting[:content_default_http_proxy] = nil
          assert_nil UpstreamCandlepinResource.proxy_uri
        end

        def test_global_proxy
          ForemanTasks.stubs(:async_task) #prevent global proxy setting callback
          proxy = FactoryBot.create(:http_proxy, :url => 'http://foo.com:1000', :username => 'admin', :password => 'password')
          Setting[:content_default_http_proxy] = proxy.name

          assert_equal 'proxy://admin:password@foo.com:1000', UpstreamCandlepinResource.proxy_uri
        end

        def test_global_proxy_no_cacert
          proxy = FactoryBot.create(:http_proxy, :url => 'http://foo.com:1000',
                                    :username => 'admin',
                                    :password => 'password',
                                    :cacert => "")
          UpstreamCandlepinResource.stubs(:proxy).returns(proxy)
          Foreman::Util.expects(:add_ca_bundle_to_store).never
          OpenSSL::X509::Certificate.expects(:new)
          OpenSSL::PKey::RSA.expects(:new)
          UpstreamCandlepinResource.resource(url: "http://www.foo.com", client_cert: "", client_key: "")
        end

        def test_default_headers_excludes_cp_user_and_cp_consumer
          User.stubs(:cp_oauth_header).returns({'cp-user' => 'admin'})

          headers = UpstreamCandlepinResource.default_headers

          refute headers.key?('cp-user'), "UpstreamCandlepinResource should not include 'cp-user' header"
          refute headers.key?('cp-consumer'), "UpstreamCandlepinResource should not include 'cp-consumer' header"

          assert headers.key?('accept'), "Headers should still include 'accept'"
          assert headers.key?('content-type'), "Headers should still include 'content-type'"
        end

        def test_default_headers_excludes_cp_consumer_with_uuid
          User.stubs(:consumer?).returns(true)
          User.stubs(:cp_oauth_header).returns({'cp-consumer' => 'test-uuid'})

          headers = UpstreamCandlepinResource.default_headers('hypervisor-uuid')

          refute headers.key?('cp-user'), "UpstreamCandlepinResource should not include 'cp-user' header"
          refute headers.key?('cp-consumer'), "UpstreamCandlepinResource should not include 'cp-consumer' header even with uuid parameter"

          assert headers.key?('accept'), "Headers should still include 'accept'"
          assert headers.key?('content-type'), "Headers should still include 'content-type'"
        end

        def test_site_preserves_non_default_port
          upstream = {
            'apiUrl' => 'https://subscription.example.com:8443/subscription/consumers/uuid-1',
            'idCert' => { 'cert' => 'cert-data', 'key' => 'key-data' },
            'uuid' => 'uuid-1',
          }
          Organization.stubs(:current).returns(stub(id: 7, owner_details: { 'upstreamConsumer' => upstream }))

          assert_equal 'https://subscription.example.com:8443', UpstreamCandlepinResource.site
        end

        def test_upstream_consumer_get_uses_rest_client_path
          User.stubs(:cp_oauth_header).returns({})
          UpstreamConsumer.stubs(:upstream_consumer_id).returns('uuid-1')
          resource = mock('upstream_rest_client')
          response = stub(body: '{"uuid":"uuid-1"}', code: 200, headers: { x_version: '4.3.1' })

          resource.expects(:get).with(UpstreamConsumer.default_headers).returns(response)
          UpstreamConsumer.expects(:rest_client).with(
            Net::HTTP::Get,
            :get,
            '/subscription/consumers/uuid-1?consumerType=system'
          ).returns(resource)

          result = UpstreamConsumer.get('consumerType' => 'system')

          assert_equal 'uuid-1', result['uuid']
        end

        def test_reset_connection_clears_cached_upstream_owner
          upstream = {
            'apiUrl' => 'https://subscription.example.com/subscription/consumers/uuid-1',
            'idCert' => { 'cert' => 'cert-data', 'key' => 'key-data' },
            'uuid' => 'uuid-1',
          }
          Organization.stubs(:current).returns(stub(id: 7, owner_details: { 'upstreamConsumer' => upstream }))

          first_resource = mock('first_resource')
          first_resource.expects(:get).returns(stub(body: '{"owner":{"key":"owner-one"}}'))
          second_resource = mock('second_resource')
          second_resource.expects(:get).returns(stub(body: '{"owner":{"key":"owner-two"}}'))
          UpstreamConsumer.expects(:resource).twice.returns(first_resource, second_resource)

          assert_equal 'owner-one', UpstreamCandlepinResource.upstream_owner_id
          assert_equal 'owner-one', UpstreamCandlepinResource.upstream_owner_id

          UpstreamCandlepinResource.reset_connection!

          assert_equal 'owner-two', UpstreamCandlepinResource.upstream_owner_id
        end
      end

      class CandlepinResourceTest < ActiveSupport::TestCase
        def test_default_headers_includes_cp_oauth_header
          User.stubs(:cp_oauth_header).returns({'cp-user' => 'admin'})

          headers = CandlepinResource.default_headers

          assert headers.key?('cp-user'), "CandlepinResource should include 'cp-user' header for local Candlepin"
          assert_equal 'admin', headers['cp-user']
        end
      end

      class OwnerTest < ActiveSupport::TestCase
        def test_destroy_imports_parses_response_body
          User.stubs(:cp_oauth_header).returns({})
          Owner.expects(:delete).with(
            '/candlepin/owners/acme/imports',
            Owner.default_headers
          ).returns(stub(body: '{"state":"FINISHED"}'))

          response = Owner.destroy_imports('acme')

          assert_equal 'FINISHED', response['state']
        end
      end

      class UpstreamJobTest < ActiveSupport::TestCase
        def test_get_parses_upstream_response_body
          upstream = {
            'apiUrl' => 'https://subscription.example.com/subscription/consumers/uuid-1',
            'idCert' => { 'cert' => 'cert-data', 'key' => 'key-data' },
          }
          UpstreamConsumer.expects(:start_upstream_export).with(
            'https://subscription.example.com/subscription/jobs/job-1',
            'cert-data',
            'key-data',
            nil
          ).returns(stub(body: '{"state":"FINISHED"}'))

          response = UpstreamJob.get('job-1', upstream)

          assert_equal 'FINISHED', response[:state]
        end
      end

      class ProductTest < ActiveSupport::TestCase
        def setup
        end

        def test_create_unlimited_subsciption
          product_id = 3
          owner = Organization.first
          start_date = Time.parse('2020-01-10 07:07:47 +0000')
          end_date = Time.parse('2049-12-01 00:00:00 +0000')
          expected_pool = {
            'startDate' => start_date,
            'endDate' => end_date,
            'quantity' => -1,
            'accountNumber' => '',
            'productId' => product_id,
            'providedProducts' => [],
            'contractNumber' => '',
          }

          ::Katello::Resources::Candlepin::Pool.expects(:create).with(owner.label, expected_pool).returns('{}')
          ::Katello::Resources::Candlepin::Product.create_unlimited_subscription(owner.label, product_id, start_date)
        end
      end
    end
  end
end
