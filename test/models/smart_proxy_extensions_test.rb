require 'katello_test_helper'

module Katello
  class SmartProxyExtensionsTest < ActiveSupport::TestCase
    let(:lb_hostname) { 'proxy-lb.example.com' }
    let(:lb_url) { "https://#{lb_hostname}:9090" }
    let(:backend1_hostname) { 'proxy-backend-1.example.com' }
    let(:backend2_hostname) { 'proxy-backend-2.example.com' }

    let(:backend1) { FactoryBot.build_stubbed(:smart_proxy, url: "https://#{backend1_hostname}:9090") }
    let(:backend2) { FactoryBot.build_stubbed(:smart_proxy, url: "https://#{backend2_hostname}:9090") }
    let(:standalone) { FactoryBot.build_stubbed(:smart_proxy, url: lb_url) }

    def setup
      backend1.stubs(:registration_url).returns(URI(lb_url))
      backend2.stubs(:registration_url).returns(URI(lb_url))
      standalone.stubs(:registration_url).returns(URI(lb_url))
    end

    def test_load_balanced_returns_true_when_url_host_differs_from_registration_host
      assert backend1.load_balanced?
    end

    def test_load_balanced_returns_false_when_url_host_matches_registration_host
      refute standalone.load_balanced?
    end

    def test_lb_backend_hostnames_returns_backend_hostnames_for_load_balanced_proxy
      ::SmartProxy.stubs(:behind_load_balancer).with(lb_hostname).returns([backend1, backend2])
      assert_equal [backend1_hostname, backend2_hostname], backend1.lb_backend_hostnames
    end

    def test_lb_backend_hostnames_returns_empty_array_for_non_load_balanced_proxy
      assert_equal [], standalone.lb_backend_hostnames
    end
  end
end
