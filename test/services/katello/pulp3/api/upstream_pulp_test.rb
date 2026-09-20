require 'katello_test_helper'

module Katello
  module Pulp3
    module Api
      class UpstreamPulpTest < ActiveSupport::TestCase
        let(:service) { ::Katello::Pulp3::Api::UpstreamPulp.new(::SmartProxy.pulp_primary) }

        it 'memoizes the api client across calls' do
          assert_same service.api_client, service.api_client
        end

        it 'memoizes upstream_pulps_api across calls' do
          assert_same service.upstream_pulps_api, service.upstream_pulps_api
        end

        it 'skips partial_update when nothing comparable has changed' do
          existing = OpenStruct.new(pulp_href: '/href/', base_url: 'https://x', policy: 'labeled', client_cert: 'cert')
          service.stubs(:find_by_name).returns(existing)
          service.upstream_pulps_api.expects(:partial_update).never

          href = service.send(:create_or_update, 'name', base_url: 'https://x', policy: 'labeled', client_cert: 'cert', client_key: 'new-key')

          assert_equal '/href/', href
        end

        it 'calls partial_update when a comparable field changed' do
          existing = OpenStruct.new(pulp_href: '/href/', base_url: 'https://old', policy: 'labeled', client_cert: 'cert')
          service.stubs(:find_by_name).returns(existing)
          service.upstream_pulps_api.expects(:partial_update).with('/href/', anything)

          service.send(:create_or_update, 'name', base_url: 'https://new', policy: 'labeled', client_cert: 'cert')
        end

        it 'treats unknown comparable fields as needing update' do
          existing = OpenStruct.new(pulp_href: '/href/', base_url: 'https://x', policy: 'labeled')
          service.stubs(:find_by_name).returns(existing)
          service.upstream_pulps_api.expects(:partial_update).with('/href/', satisfies { |payload| payload[:api_root] == '/pulp/' })

          service.send(:create_or_update, 'name', base_url: 'https://x', policy: 'labeled', api_root: '/pulp/')
        end

        it 'submits endpoint profiles and replication requests as plain hashes' do
          profile = stub(name: 'endpoint', to_h: { base_url: 'https://sat.example.com', api_root: '/pulp/' })
          request = stub(to_h: { repository_ids: [1], force_sync: true, prune: false })

          service.expects(:create_or_update).with('endpoint', profile.to_h).returns('/href/')
          service.upstream_pulps_api.expects(:replicate).with('/href/', request.to_h)

          assert_equal '/href/', service.ensure_endpoint(profile)
          service.replicate('/href/', request)
        end

        it 'recovers from a create race only when the error looks like a name uniqueness conflict' do
          winner = OpenStruct.new(pulp_href: '/winner/', base_url: 'https://x', policy: 'labeled')
          service.stubs(:find_by_name).returns(nil, winner)
          service.upstream_pulps_api.expects(:create).raises(
            PulpcoreClient::ApiError.new("{'name': [ErrorDetail(string='This field must be unique.', code='unique')]}")
          )
          service.upstream_pulps_api.expects(:partial_update).never

          href = service.send(:create_or_update, 'name', base_url: 'https://x', policy: 'labeled')

          assert_equal '/winner/', href
        end

        it 're-raises unrelated create errors even if a same-named record later exists' do
          winner = OpenStruct.new(pulp_href: '/winner/', base_url: 'https://x', policy: 'labeled')
          service.stubs(:find_by_name).returns(nil, winner)
          service.upstream_pulps_api.expects(:create).raises(PulpcoreClient::ApiError.new('503 Service Unavailable'))
          service.upstream_pulps_api.expects(:partial_update).never

          assert_raises(PulpcoreClient::ApiError) do
            service.send(:create_or_update, 'name', base_url: 'https://x', policy: 'labeled')
          end
        end
      end
    end
  end
end
