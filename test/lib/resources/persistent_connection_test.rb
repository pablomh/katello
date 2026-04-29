require 'katello_test_helper'

module Katello
  module Resources
    module Candlepin
      class PooledResponseTest < ActiveSupport::TestCase
        def setup
          @net_response = stub(
            :body => '{"id":"abc","name":"test"}',
            :code => '200'
          )
          @net_response.stubs(:each_header).multiple_yields(
            ['X-Candlepin-Request-Uuid', 'req-123'],
            ['X-Version', '4.3.1'],
            ['Content-Type', 'application/json']
          )
          @response = PersistentConnection::PooledResponse.new(@net_response, url: 'https://localhost:23443/candlepin/consumers/uuid-1')
        end

        def test_body_returns_response_body
          assert_equal '{"id":"abc","name":"test"}', @response.body
        end

        def test_code_returns_integer
          assert_equal 200, @response.code
          assert_kind_of Integer, @response.code
        end

        def test_headers_uses_symbol_keys_with_underscores
          assert_equal 'req-123', @response.headers[:x_candlepin_request_uuid]
          assert_equal '4.3.1', @response.headers[:x_version]
          assert_equal 'application/json', @response.headers[:content_type]
        end

        def test_request_url
          assert_equal 'https://localhost:23443/candlepin/consumers/uuid-1', @response.request.url
        end

        def test_inherits_from_string
          assert_kind_of String, @response
          assert_equal '{"id":"abc","name":"test"}', @response.to_s
        end

        def test_json_parseable_as_string
          parsed = JSON.parse(@response)
          assert_equal 'abc', parsed['id']
        end

        def test_code_supports_integer_comparison
          assert @response.code < 400
          error_response = PersistentConnection::PooledResponse.new(
            stub(:body => '{}', :code => '404').tap { |r| r.stubs(:each_header) },
            url: 'https://localhost/test'
          )
          assert error_response.code >= 400
        end
      end

      class PersistentConnectionIssueRequestTest < ActiveSupport::TestCase
        def setup
          @success_response = stub(:body => '{"status":"ok"}', :code => '200')
          @success_response.stubs(:each_header).multiple_yields(
            ['X-Candlepin-Request-Uuid', 'req-456'],
            ['X-Version', '4.3.1']
          )
          @mock_conn = mock('net_http')
          @mock_conn.stubs(:started?).returns(true)
        end

        def test_successful_request_returns_pooled_response
          @mock_conn.expects(:request).returns(@success_response)
          Thread.current[PersistentConnection::THREAD_KEY] = @mock_conn

          result = CandlepinResource.issue_request(method: :get, path: '/candlepin/status', headers: {})

          assert_kind_of PersistentConnection::PooledResponse, result
          assert_equal 200, result.code
          assert_equal '{"status":"ok"}', result.body
        ensure
          Thread.current[PersistentConnection::THREAD_KEY] = nil
        end

        def test_4xx_raises_restclient_exception
          error_response = stub(:body => '{"displayMessage":"Not found"}', :code => '404')
          error_response.stubs(:each_header).multiple_yields(['X-Version', '4.3.1'])
          @mock_conn.expects(:request).returns(error_response)
          Thread.current[PersistentConnection::THREAD_KEY] = @mock_conn

          assert_raises(RestClient::Exception) do
            CandlepinResource.issue_request(method: :get, path: '/candlepin/missing', headers: {})
          end
        ensure
          Thread.current[PersistentConnection::THREAD_KEY] = nil
        end

        def test_404_without_x_version_raises_candlepin_not_running
          error_response = stub(:body => '<html>404</html>', :code => '404')
          error_response.stubs(:each_header)
          @mock_conn.expects(:request).returns(error_response)
          Thread.current[PersistentConnection::THREAD_KEY] = @mock_conn

          assert_raises(Katello::Errors::CandlepinNotRunning) do
            CandlepinResource.issue_request(method: :get, path: '/candlepin/status', headers: {})
          end
        ensure
          Thread.current[PersistentConnection::THREAD_KEY] = nil
        end

        def test_stale_connection_retries_once
          @mock_conn.expects(:request).raises(IOError.new('closed stream'))
          Thread.current[PersistentConnection::THREAD_KEY] = @mock_conn

          # After retry, persistent_connection creates a new conn — stub that path
          new_conn = mock('new_net_http')
          new_conn.stubs(:started?).returns(true)
          new_conn.expects(:request).returns(@success_response)
          CandlepinResource.stubs(:persistent_connection).returns(new_conn)

          result = CandlepinResource.issue_request(method: :get, path: '/candlepin/status', headers: {})
          assert_equal 200, result.code
        ensure
          Thread.current[PersistentConnection::THREAD_KEY] = nil
        end

        def test_logs_connection_reused_on_warm_thread
          @mock_conn.expects(:request).returns(@success_response)
          Thread.current[PersistentConnection::THREAD_KEY] = @mock_conn

          reg_logger = mock('registration_logger')
          reg_logger.expects(:debug).with { |msg| msg.include?('connection=REUSED') }
          reg_logger.stubs(:debug)
          ::Foreman::Logging.stubs(:logger).with('registration').returns(reg_logger)

          CandlepinResource.issue_request(method: :get, path: '/candlepin/status', headers: {})
        ensure
          Thread.current[PersistentConnection::THREAD_KEY] = nil
        end

        def test_logs_connection_new_on_cold_thread
          Thread.current[PersistentConnection::THREAD_KEY] = nil

          reg_logger = mock('registration_logger')
          reg_logger.expects(:debug).with { |msg| msg.include?('connection=NEW') }
          reg_logger.stubs(:debug)
          ::Foreman::Logging.stubs(:logger).with('registration').returns(reg_logger)

          CandlepinResource.stubs(:persistent_connection).returns(@mock_conn)
          @mock_conn.expects(:request).returns(@success_response)

          CandlepinResource.issue_request(method: :get, path: '/candlepin/status', headers: {})
        ensure
          Thread.current[PersistentConnection::THREAD_KEY] = nil
        end

        def test_upstream_resource_bypasses_pooling
          assert_equal false, UpstreamCandlepinResource.use_persistent_connection
        end
      end
    end
  end
end
