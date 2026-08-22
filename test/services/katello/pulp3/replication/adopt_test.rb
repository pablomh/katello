require 'katello_test_helper'

module Katello
  module Pulp3
    module Replication
      class AdoptTest < ActiveSupport::TestCase
        include Support::CapsuleSupport

        def setup
          @proxy = proxy_with_pulp
          @proxy.stubs(:lifecycle_environments).returns([])
          @proxy.stubs(:download_policy).returns('immediate')
          ::Cert::Certs.stubs(:ueber_cert).returns(nil)
          Replication.stubs(:satellite_pulp_base_url).returns('https://sat.example.com')
        end

        def test_adopts_each_org_independently_and_isolates_failures
          org_a = stub('org_a', :id => 1, :name => 'Org A', :label => 'org_a')
          org_b = stub('org_b', :id => 2, :name => 'Org B', :label => 'org_b')
          repo_a = stub('repo_a', :root => stub(:organization => org_a, :unprotected => true), :docker? => false, :relative_path => 'a')
          repo_b = stub('repo_b', :root => stub(:organization => org_b, :unprotected => true), :docker? => false, :relative_path => 'b')

          ProxyClient.any_instance.expects(:adopt).with(has_entries(:upstream_name => 'katello-satellite-org_a')).returns('ok' => true)
          ProxyClient.any_instance.expects(:adopt).with(has_entries(:upstream_name => 'katello-satellite-org_b')).raises(StandardError, 'boom')

          outcomes = Adopt.new(@proxy).call([repo_a, repo_b])

          assert outcomes.find { |o| o[:organization] == org_a }[:ok]
          refute outcomes.find { |o| o[:organization] == org_b }[:ok]
        end
      end
    end
  end
end
