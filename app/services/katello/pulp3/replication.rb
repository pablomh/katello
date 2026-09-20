require 'uri'

module Katello
  module Pulp3
    # Facade over three cohesive concerns (Capability, Classification, RemoteSettings),
    # extended in so callers keep using Replication.foo(...) unchanged, plus the
    # orchestration methods that tie them together.
    module Replication
      extend Capability
      extend Classification
      extend RemoteSettings

      def self.content_organization(repo)
        repo.try(:organization) || repo.root&.organization
      end

      def self.group_by_org(repos)
        Array(repos).group_by { |repo| content_organization(repo) }.reject { |org, _| org.nil? }
      end

      def self.group_by_org_and_policy(smart_proxy, repos)
        grouped = Array(repos).group_by do |repo|
          [content_organization(repo), effective_remote_download_policy(smart_proxy, repo)]
        end
        grouped.reject { |(organization, _policy), _| organization.nil? }
      end

      def self.upstream_name_for(organization)
        "katello-satellite-#{organization.label}"
      end

      def self.primary_pulp_api_uri
        URI.parse(::SmartProxy.pulp_primary.pulp3_url)
      end

      def self.primary_pulp_base_url
        uri = primary_pulp_api_uri.dup
        uri.path = ''
        uri.query = nil
        uri.fragment = nil
        uri.to_s.delete_suffix('/')
      end

      def self.primary_pulp_api_root
        primary_pulp_api_uri.path.sub(%r{/api/v3/?\z}, '/').sub(%r{/*\z}, '/')
      end

      def self.endpoint_profile_for(organization)
        EndpointProfile.new(organization)
      end

      def self.distribution_path_for(smart_proxy, repo)
        repo.backend_service(smart_proxy).relative_path
      end

      def self.ensure_upstream_pulp!(api, organization)
        api.ensure_endpoint(endpoint_profile_for(organization))
      end
    end
  end
end
