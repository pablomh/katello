require 'katello_test_helper'

module Katello
  module Resources
    module Candlepin
      class PooledTransportResponseTest < ActiveSupport::TestCase
        def setup
          @net_response = stub(body: '{"displayMessage":"Not found"}', code: '404')
          @net_response.stubs(:each_header).multiple_yields(
            ['X-Candlepin-Request-Uuid', 'req-123'],
            ['X-Version', '4.3.1'],
            ['Content-Type', 'application/json']
          )
          @response = PooledTransport::Response.new(@net_response, url: 'https://localhost:23443/candlepin/consumers/uuid-1')
        end

        def test_body_and_headers_are_exposed
          assert_equal '{"displayMessage":"Not found"}', @response.body
          assert_equal 'req-123', @response.headers[:x_candlepin_request_uuid]
          assert_equal '4.3.1', @response.headers[:x_version]
          assert_equal 'application/json', @response.headers[:content_type]
        end

        def test_response_adapter_reads_response_contract
          assert_equal '{"displayMessage":"Not found"}', ResponseAdapter.body(@response)
          assert_equal 404, ResponseAdapter.code(@response)
          assert_equal 'application/json', ResponseAdapter.content_type(@response)
        end

        def test_candlepin_error_parsing_accepts_duck_typed_response
          exception_class = Class.new do
            attr_reader :response

            def initialize(response)
              @response = response
            end

            # Duck-types Exception#set_backtrace, so the accessor-style name is required.
            # rubocop:disable Naming/AccessorMethodName
            def set_backtrace(_backtrace)
            end
            # rubocop:enable Naming/AccessorMethodName
          end
          exception = exception_class.new(@response)

          error = Katello::Errors::CandlepinError.from_exception(exception)

          assert_equal 'Not found', error.message
        end
      end

      class PersistentTransportTest < ActiveSupport::TestCase
        def test_symbol_headers_are_normalized_for_net_http
          pooled_http_client = mock('pooled_http_client')
          signer = stub(authorization_header: 'OAuth test')
          resource_class = stub(site: 'https://localhost:23443')
          success_response = stub(body: '{"status":"ok"}', code: '200')
          success_response.stubs(:each_header).multiple_yields(
            ['X-Candlepin-Request-Uuid', 'req-456'],
            ['X-Version', '4.3.1'],
            ['Content-Type', 'application/json']
          )

          request_expectation = pooled_http_client.expects(:request).with do |uri, request|
            uri.to_s == 'https://localhost:23443/candlepin/status' &&
              request['Authorization'] == 'OAuth test' &&
              request['accept'] == 'application/json' &&
              request['content-type'] == 'application/json'
          end
          request_expectation.returns(success_response)

          transport = PooledTransport::PersistentTransport.new(
            resource_class,
            pooled_http_client: pooled_http_client,
            signer: signer
          )

          result = transport.call(
            method: :get,
            path: '/candlepin/status',
            headers: { accept: :json, content_type: :json },
            payload: nil
          )

          assert_kind_of PooledTransport::Response, result
          assert_equal 200, result.code
        end

        def test_304_maps_to_restclient_not_modified
          pooled_http_client = mock('pooled_http_client')
          signer = stub(authorization_header: 'OAuth test')
          resource_class = stub(site: 'https://localhost:23443')
          not_modified_response = stub(body: '', code: '304')
          not_modified_response.stubs(:each_header).multiple_yields(['X-Version', '4.3.1'])
          pooled_http_client.expects(:request).returns(not_modified_response)

          transport = PooledTransport::PersistentTransport.new(
            resource_class,
            pooled_http_client: pooled_http_client,
            signer: signer
          )

          assert_raises(RestClient::NotModified) do
            transport.call(method: :get, path: '/candlepin/status', headers: {}, payload: nil)
          end
        end
      end

      class PersistentHttpClientTest < ActiveSupport::TestCase
        def setup
          @logger = stub(debug: true, info: true)
          @client = PooledTransport::PersistentHttpClient.new(
            site: 'https://localhost:23443',
            ca_file_resolver: -> { '/tmp/candlepin-ca.pem' },
            pool_size: 5,
            logger: @logger
          )
        end

        def teardown
          @client.reset!
        end

        def test_ca_freshness_change_rebuilds_persistent_client
          first_client = mock('http_client_one')
          second_client = mock('http_client_two')
          first_client.stubs(:shutdown).returns(true)
          second_client.stubs(:shutdown).returns(true)
          @client.stubs(:build_client).twice.returns(first_client, second_client)
          File.stubs(:exist?).with('/tmp/candlepin-ca.pem').returns(true)
          File.stubs(:stat).with('/tmp/candlepin-ca.pem').returns(
            stub(size: 128, mtime: Time.at(100)),
            stub(size: 128, mtime: Time.at(101))
          )

          uri = URI.parse('https://localhost:23443/candlepin/status')
          request = stub('request')
          first_client.expects(:request).with(uri, request).returns(:first_result)
          second_client.expects(:request).with(uri, request).returns(:second_result)

          assert_equal :first_result, @client.request(uri, request)
          assert_equal :second_result, @client.request(uri, request)
        end

        def test_ca_freshness_token_uses_file_stat
          File.stubs(:exist?).with('/tmp/candlepin-ca.pem').returns(true)
          File.stubs(:stat).with('/tmp/candlepin-ca.pem').returns(
            stub(size: 128, mtime: Time.at(100)),
            stub(size: 128, mtime: Time.at(100)),
            stub(size: 128, mtime: Time.at(101))
          )

          assert_equal ['/tmp/candlepin-ca.pem', 128, 100.0], @client.send(:current_ssl_ca_freshness_token)
          assert_equal ['/tmp/candlepin-ca.pem', 128, 100.0], @client.send(:current_ssl_ca_freshness_token)
          assert_equal ['/tmp/candlepin-ca.pem', 128, 101.0], @client.send(:current_ssl_ca_freshness_token)
        end

        def test_persistent_http_build_is_mutex_guarded
          shared_client = mock('shared_http_client')
          shared_client.stubs(:shutdown).returns(true)
          shared_client.expects(:request).twice.returns(:ok)
          build_count = 0
          build_count_mutex = Mutex.new
          build_started = Queue.new
          build_release = Queue.new

          File.stubs(:exist?).with('/tmp/candlepin-ca.pem').returns(true)
          File.stubs(:stat).with('/tmp/candlepin-ca.pem').returns(stub(size: 128, mtime: Time.at(100)))
          builder = lambda do |ca_file:|
            fail "unexpected ca_file #{ca_file}" unless ca_file == '/tmp/candlepin-ca.pem'
            build_count_mutex.synchronize { build_count += 1 }
            build_started << true
            build_release.pop
            shared_client
          end

          @client.define_singleton_method(:build_client, &builder)
          uri = URI.parse('https://localhost:23443/candlepin/status')
          request = stub('request')

          thread_one = Thread.new { @client.request(uri, request) }
          build_started.pop
          thread_two = Thread.new { @client.request(uri, request) }

          sleep 0.1
          2.times { build_release << true }

          assert_equal :ok, thread_one.value
          assert_equal :ok, thread_two.value
          assert_equal 1, build_count
        end

        def test_build_client_configures_rotation_limits
          timeout = SETTINGS[:katello][:rest_client_timeout]
          http = mock('net_http_persistent')
          http.expects(:ca_file=).with('/tmp/candlepin-ca.pem')
          http.expects(:open_timeout=).with(timeout)
          http.expects(:read_timeout=).with(timeout)
          http.expects(:idle_timeout=).with(PooledTransport::PersistentHttpClient::DEFAULT_IDLE_TIMEOUT)
          http.expects(:max_requests=).with(PooledTransport::PersistentHttpClient::DEFAULT_MAX_REQUESTS)
          Net::HTTP::Persistent.expects(:new).with(name: 'candlepin', pool_size: 5).returns(http)

          result = @client.send(:build_client, ca_file: '/tmp/candlepin-ca.pem')

          assert_same http, result
        end

        def test_configured_max_requests_uses_environment_override
          ENV.expects(:fetch)
            .with('KATELLO_CANDLEPIN_PERSISTENT_MAX_REQUESTS', PooledTransport::PersistentHttpClient::DEFAULT_MAX_REQUESTS)
            .returns('250')

          assert_equal 250, @client.send(:configured_max_requests)
        end

        def test_configured_idle_timeout_uses_environment_override
          ENV.expects(:fetch)
            .with('KATELLO_CANDLEPIN_PERSISTENT_IDLE_TIMEOUT', PooledTransport::PersistentHttpClient::DEFAULT_IDLE_TIMEOUT)
            .returns('9')

          assert_equal 9, @client.send(:configured_idle_timeout)
        end

        def test_connection_error_is_reraised_without_discarding_the_pool
          shared_client = mock('shared_http_client')
          sequence = sequence('requests')
          shared_client.expects(:request).raises(Net::HTTP::Persistent::Error.new('connection reset by peer')).in_sequence(sequence)
          shared_client.expects(:request).returns(:ok).in_sequence(sequence)
          shared_client.stubs(:shutdown).returns(true)
          @client.stubs(:build_client).once.returns(shared_client)
          File.stubs(:exist?).with('/tmp/candlepin-ca.pem').returns(true)
          File.stubs(:stat).with('/tmp/candlepin-ca.pem').returns(stub(size: 128, mtime: Time.at(100)))

          uri = URI.parse('https://localhost:23443/candlepin/status')
          request = stub('request')

          assert_raises(Net::HTTP::Persistent::Error) do
            @client.request(uri, request)
          end

          assert_same shared_client, @client.instance_variable_get(:@client)
          assert_equal :ok, @client.request(uri, request)
        end
      end

      class RestClientTransportTest < ActiveSupport::TestCase
        def test_get_fallback_does_not_pass_payload_positionally
          resource_class = stub(
            site: 'https://localhost:23443',
            current_ssl_ca_file: nil,
            ssl_client_cert: nil,
            ssl_client_key: nil
          )
          signer = stub(authorization_header: 'OAuth test')
          client = mock('rest_client_resource')
          client.expects(:get).with({ 'accept' => 'application/json' }).returns(
            stub(code: 200, body: '{"status":"ok"}', headers: { x_version: '4.3.1' })
          )

          transport = PooledTransport::RestClientTransport.new(resource_class, signer: signer)
          transport.stubs(:resource).returns(client)

          result = transport.call(
            method: :get,
            path: '/candlepin/status',
            headers: { 'accept' => 'application/json' },
            payload: { ignored: true }
          )

          assert_equal 200, result.code
        end
      end

      class CandlepinResourceTransportTest < ActiveSupport::TestCase
        def setup
          @original_setting = Setting[:candlepin_pooled_http_enabled]
          Setting[:candlepin_pooled_http_enabled] = true
          CandlepinResource.reset_persistent_http!
        end

        def teardown
          Setting[:candlepin_pooled_http_enabled] = @original_setting
          CandlepinResource.reset_persistent_http!
        end

        def test_issue_request_uses_pooled_transport
          response = stub(code: 200, headers: { x_candlepin_request_uuid: 'req-456', x_version: '4.3.1' }, body: '{"status":"ok"}')
          CandlepinResource.expects(:persistent_transport).returns(mock_transport = mock('persistent_transport'))
          CandlepinResource.expects(:rest_client_transport).never
          mock_transport.expects(:call).with(
            method: :get,
            path: '/candlepin/status',
            headers: {},
            payload: nil
          ).returns(response)

          result = CandlepinResource.issue_request(method: :get, path: '/candlepin/status', headers: {})

          assert_same response, result
          assert_equal 200, result.code
        end

        def test_hash_payloads_fall_back_to_rest_client
          response = stub(code: 200, headers: { x_candlepin_request_uuid: 'req-789', x_version: '4.3.1' }, body: '{"status":"ok"}')
          CandlepinResource.expects(:rest_client_transport).returns(mock_transport = mock('rest_client_transport'))
          CandlepinResource.expects(:persistent_transport).never
          mock_transport.expects(:call).with(
            method: :post,
            path: '/candlepin/owners/org/imports/async',
            headers: { 'accept' => 'application/json' },
            payload: { import: 'file_object' }
          ).returns(response)

          result = CandlepinResource.issue_request(
            method: :post,
            path: '/candlepin/owners/org/imports/async',
            headers: { 'accept' => 'application/json' },
            payload: { import: 'file_object' }
          )

          assert_equal 200, result.code
        end

        def test_setting_disables_pooled_transport
          Setting[:candlepin_pooled_http_enabled] = false
          response = stub(code: 200, headers: { x_candlepin_request_uuid: 'req-000', x_version: '4.3.1' }, body: '{"status":"ok"}')
          CandlepinResource.expects(:rest_client_transport).returns(mock_transport = mock('rest_client_transport'))
          CandlepinResource.expects(:persistent_transport).never
          mock_transport.expects(:call).with(
            method: :get,
            path: '/candlepin/status',
            headers: {},
            payload: nil
          ).returns(response)

          result = CandlepinResource.issue_request(method: :get, path: '/candlepin/status', headers: {})

          assert_equal 200, result.code
        end

        def test_update_content_overrides_delete_uses_issue_request
          CandlepinResource.expects(:put).never
          CandlepinResource.expects(:issue_request).with(
            method: :delete,
            path: '/candlepin/consumers/uuid-1/content_overrides',
            headers: CandlepinResource.default_headers,
            payload: '[{"name":"enabled","value":null}]'
          ).returns(stub(body: '[]'))

          result = CandlepinResource.update_content_overrides_for(
            '/candlepin/consumers/uuid-1',
            [{ name: 'enabled', value: nil }]
          )

          assert_equal '[]', result.body
        end
      end

      class ProxyHeaderMergeTest < ActiveSupport::TestCase
        def test_get_merges_default_headers_without_mutating_callers_hash
          CandlepinResource.stubs(:default_headers).returns(
            'accept' => 'application/json',
            'X-Correlation-ID' => 'req-123'
          )

          extra_headers = { 'If-None-Match' => 'etag-1' }
          CandlepinResource.expects(:issue_request).with(
            method: :get,
            path: '/candlepin/status',
            headers: {
              'accept' => 'application/json',
              'X-Correlation-ID' => 'req-123',
              'If-None-Match' => 'etag-1',
            }
          ).returns(stub(body: '', code: 200, headers: {}))

          Proxy.get('/status', extra_headers)

          assert_equal({ 'If-None-Match' => 'etag-1' }, extra_headers)
        end
      end

      class ResponseAdapterFallbackTest < ActiveSupport::TestCase
        def test_nil_response_adapts_to_empty_body_and_default_content_type
          assert_equal '', ResponseAdapter.body(nil)
          assert_equal 'application/json', ResponseAdapter.content_type(stub(code: 200))
        end
      end
    end
  end
end
