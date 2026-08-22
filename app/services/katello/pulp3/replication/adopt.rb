module Katello
  module Pulp3
    module Replication
      # Stamp existing Capsule remotes/repos/distros with UpstreamPulp=<pk> so
      # policy=labeled will manage them. Lookup-by-base_path then rename happens
      # inside pulpcore replicate() (3.113+). Wipe is forbidden (SAT-36270).
      class Adopt
        def initialize(smart_proxy)
          @smart_proxy = smart_proxy
        end

        # One adopt call per org: a cert problem or proxy error for one org
        # does not stop the others on the same Capsule.
        def call(repos = nil)
          repos ||= ::Katello::SmartProxyHelper.new(@smart_proxy).repositories_available_to_capsule
          proxy_client = ProxyClient.new(@smart_proxy)
          Replication.group_by_org(repos).map { |organization, org_repos| adopt_for_org(proxy_client, organization, org_repos) }
        end

        private

        def adopt_for_org(proxy_client, organization, repos)
          result = proxy_client.adopt(
            upstream_name: Replication.upstream_name_for(organization),
            satellite_base_url: Replication.satellite_pulp_base_url,
            policy: 'labeled',
            adopt_base_paths: repos.map { |repo| Replication.distribution_path_for(repo) },
            stored_q_select: Replication.q_select_for(lifecycle_environments: @smart_proxy.lifecycle_environments),
            remote_download_policy: Replication.remote_download_policy(@smart_proxy, repos),
            **Replication.remote_credentials_for(organization)
          )
          { :organization => organization, :ok => true, :result => result }
        rescue StandardError => e
          Rails.logger.warn("Adopt failed for Capsule #{@smart_proxy.name} / organization #{organization.name}: #{e.message}")
          { :organization => organization, :ok => false, :error => e.message }
        end
      end
    end
  end
end
