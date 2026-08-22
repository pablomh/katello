module Katello
  module Pulp3
    module Replication
      # Satellite talks to Capsule Pulp only through Foreman Proxy for UpstreamPulp.
      # Never POST /pulp/api/v3/upstream-pulps/ with Satellite Ruby gems (SAT-39084).
      class ProxyClient
        delegate :replicate, :adopt, to: :api

        def initialize(smart_proxy)
          @smart_proxy = smart_proxy
        end

        private

        def api
          @api ||= begin
            proxy = ::Katello::Pulp3::Replication.foreman_proxy_for(@smart_proxy)
            ::ProxyAPI::PulpcoreReplicate.new(:url => proxy.url)
          end
        end
      end
    end
  end
end
