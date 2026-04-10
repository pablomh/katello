require 'katello_test_helper'

module Katello
  module Resources
    module Candlepin
      class CandlepinPingTest < ActiveSupport::TestCase
        def setup
          Rails.cache.delete(CandlepinPing::CACHE_KEY)
        end

        def teardown
          Rails.cache.delete(CandlepinPing::CACHE_KEY)
        end

        # ping — cache-first (default, force: false)

        def test_ping_serves_from_warm_cache
          cached_response = {'mode' => 'NORMAL', 'managerCapabilities' => []}.with_indifferent_access
          Rails.cache.write(CandlepinPing::CACHE_KEY, cached_response, expires_in: CandlepinPing::CACHE_TTL)

          CandlepinPing.expects(:get).never

          result = CandlepinPing.ping

          assert_equal 'NORMAL', result['mode']
        end

        def test_ping_fetches_from_candlepin_on_cold_miss
          response = {'mode' => 'NORMAL', 'managerCapabilities' => []}.with_indifferent_access
          CandlepinPing.expects(:get).once.returns(stub(:body => response.to_json))

          result = CandlepinPing.ping

          assert_equal 'NORMAL', result['mode']
        end

        def test_ping_writes_to_cache_on_cold_miss
          response = {'mode' => 'NORMAL', 'managerCapabilities' => []}.with_indifferent_access
          CandlepinPing.stubs(:get).returns(stub(:body => response.to_json))

          CandlepinPing.ping

          assert_not_nil Rails.cache.read(CandlepinPing::CACHE_KEY)
        end

        # ping(force: true) — always hits Candlepin, used by health-check callers

        def test_ping_force_fetches_from_candlepin
          response = {'mode' => 'NORMAL', 'managerCapabilities' => []}.with_indifferent_access
          CandlepinPing.expects(:get).returns(stub(:body => response.to_json))

          result = CandlepinPing.ping(force: true)

          assert_equal 'NORMAL', result['mode']
        end

        def test_ping_force_writes_to_cache
          response = {'mode' => 'NORMAL', 'managerCapabilities' => []}.with_indifferent_access
          CandlepinPing.stubs(:get).returns(stub(:body => response.to_json))

          CandlepinPing.ping(force: true)

          assert_not_nil Rails.cache.read(CandlepinPing::CACHE_KEY)
        end

        def test_ping_force_bypasses_existing_cache
          stale = {'mode' => 'SUSPEND', 'managerCapabilities' => []}.with_indifferent_access
          Rails.cache.write(CandlepinPing::CACHE_KEY, stale, expires_in: CandlepinPing::CACHE_TTL)

          fresh = {'mode' => 'NORMAL', 'managerCapabilities' => []}.with_indifferent_access
          CandlepinPing.expects(:get).returns(stub(:body => fresh.to_json))

          result = CandlepinPing.ping(force: true)

          assert_equal 'NORMAL', result['mode']
        end

        # ok?

        def test_ok_returns_true_when_normal
          CandlepinPing.stubs(:ping).returns({'mode' => 'NORMAL'}.with_indifferent_access)
          assert CandlepinPing.ok?
        end

        def test_ok_returns_false_when_suspended
          CandlepinPing.stubs(:ping).returns({'mode' => 'SUSPEND'}.with_indifferent_access)
          refute CandlepinPing.ok?
        end

        def test_ok_calls_ping_with_no_arguments
          CandlepinPing.expects(:ping).with().returns({'mode' => 'NORMAL'}.with_indifferent_access)
          CandlepinPing.ok?
        end

        # cache HIT/MISS logging

        def test_ping_logs_cache_miss_on_cold_start
          CandlepinPing.stubs(:get).returns(stub(:body => {'mode' => 'NORMAL'}.to_json))
          reg_logger = mock('registration_logger')
          reg_logger.expects(:debug).with { |msg| msg.include?('rhsm_status cache=MISS') }
          reg_logger.stubs(:debug)
          ::Foreman::Logging.stubs(:logger).with('registration').returns(reg_logger)

          CandlepinPing.ping
        end

        def test_ping_logs_cache_hit_on_warm_cache
          Rails.cache.write(CandlepinPing::CACHE_KEY, {'mode' => 'NORMAL'}.with_indifferent_access,
                            expires_in: CandlepinPing::CACHE_TTL)
          CandlepinPing.expects(:get).never
          reg_logger = mock('registration_logger')
          reg_logger.expects(:debug).with { |msg| msg.include?('rhsm_status cache=HIT') }
          ::Foreman::Logging.stubs(:logger).with('registration').returns(reg_logger)

          CandlepinPing.ping
        end
      end
    end
  end
end
