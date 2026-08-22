module Katello
  module Pulp3
    module Replication
      # Per-request q_select and base_path reuse need pulpcore 3.113.
      MIN_PULPCORE_VERSION = Gem::Version.new('3.113.0')
      # Must match Feature.name / proxy plugin :pulpcore_replicate (name_map strips spaces only).
      PROXY_FEATURE = 'Pulpcore_Replicate'.freeze

      # yum: publication is recovered from repository_version. container: no publication.
      # file/deb/ansible/ostree/python stay on the classic Capsule loop until those
      # plugins ship a working replicator and serve-after-finalize is verified.
      REPLICABLE_TYPES = %w[yum docker].freeze

      def self.capsule_enabled?
        Setting[:pulp_replicate_capsule_sync]
      end

      def self.replicable_type?(repo)
        REPLICABLE_TYPES.include?(repo.content_type)
      end

      def self.capable?(smart_proxy)
        return false unless capsule_enabled?
        return false unless smart_proxy&.has_feature?(::SmartProxy::PULP3_FEATURE)
        return false unless pulpcore_version_ok?(smart_proxy)
        proxy_action_available?(smart_proxy)
      end

      def self.pulpcore_version_ok?(smart_proxy)
        version = pulpcore_version(smart_proxy)
        version && version >= MIN_PULPCORE_VERSION
      rescue StandardError => e
        Rails.logger.debug("Could not determine pulpcore version for #{smart_proxy&.name}: #{e.message}")
        false
      end

      def self.pulpcore_version(smart_proxy)
        # One ping_pulp3 per SmartProxy object per plan (setting-on path only).
        cached = smart_proxy.instance_variable_get(:@_katello_pulpcore_version)
        return cached if smart_proxy.instance_variable_defined?(:@_katello_pulpcore_version)

        status = smart_proxy.ping_pulp3
        versions = status['versions'] || status[:versions] || []
        core = versions.find do |entry|
          component = entry['component'] || entry[:component]
          %w[core pulpcore].include?(component)
        end
        version = if core
                    raw = (core['version'] || core[:version]).to_s
                    numeric = raw[/\d+\.\d+\.\d+/]
                    Gem::Version.new(numeric) if numeric
                  end
        smart_proxy.instance_variable_set(:@_katello_pulpcore_version, version)
        version
      end

      def self.proxy_action_available?(smart_proxy)
        return true if smart_proxy.has_feature?(PROXY_FEATURE)
        # Containerized Capsules register Pulpcore on a *-pulp SmartProxy and
        # Foreman Proxy plugins on the colocated :8443 record.
        smart_proxy.self_or_colocated_with_feature(PROXY_FEATURE).present?
      rescue StandardError
        false
      end

      def self.foreman_proxy_for(smart_proxy)
        return smart_proxy if smart_proxy.has_feature?(PROXY_FEATURE)
        companion = smart_proxy.self_or_colocated_with_feature(PROXY_FEATURE)
        return companion if companion
        fail _("Smart proxy '%{name}' has no %{feature} feature") % { :name => smart_proxy.name, :feature => PROXY_FEATURE }
      end

      def self.q_select_for(environment: nil, content_view: nil, repository: nil, lifecycle_environments: nil)
        DistributionLabels.q_select(
          environment: environment,
          content_view: content_view,
          repository: repository,
          lifecycle_environments: lifecycle_environments
        )
      end

      def self.partition(repos)
        Array(repos).partition { |repo| replicable_type?(repo) }
      end

      def self.content_organization(repo)
        repo.try(:organization) || repo.root&.organization
      end

      # One UpstreamPulp per org: each org's replicable repos replicate
      # independently, so one org's cert never blocks another org's sync.
      def self.group_by_org(repos)
        Array(repos).group_by { |repo| content_organization(repo) }.reject { |org, _| org.nil? }
      end

      def self.upstream_name_for(organization)
        "katello-satellite-#{organization.label}"
      end

      # The org ueber cert is applied to content remotes, distinct from the
      # Satellite API client_cert/client_key used to authenticate to Pulp itself.
      def self.remote_credentials_for(organization)
        cert = ::Cert::Certs.ueber_cert(organization)
        return {} unless cert
        { :remote_client_cert => cert[:cert], :remote_client_key => cert[:key] }
      end

      def self.distribution_path_for(repo)
        if repo.docker?
          repo.container_repository_name
        else
          repo.relative_path.to_s.sub(%r{^/}, '')
        end
      end

      def self.satellite_pulp_base_url
        SmartProxy.pulp_primary.pulp3_uri!.to_s.sub(%r{/pulp/api/v3/?$}, '')
      end

      def self.assert_single_content_org!(repos, organization = nil)
        org_ids = Array(repos).filter_map { |repo| content_organization(repo)&.id }.uniq
        if organization
          return if org_ids.empty? || org_ids == [organization.id]
          fail _("Pulp replicate() uses one content certificate for all remotes. This Capsule sync includes a repository outside organization %{org}.") % { :org => organization.name }
        else
          return if org_ids.size <= 1
          fail _("Pulp replicate() uses one content certificate for all remotes. This Capsule sync includes repositories from multiple organizations.")
        end
      end

      def self.remote_download_policy(smart_proxy, repos)
        policy = smart_proxy.download_policy
        return policy unless policy.to_s == ::SmartProxy::DOWNLOAD_INHERIT
        repo_policies = Array(repos).map { |repo| repo.root&.download_policy }.compact.uniq
        return repo_policies.first if repo_policies.size == 1
        if repo_policies.size > 1
          Rails.logger.warn("Capsule download policy is inherit and repositories disagree; using default_proxy_download_policy=#{Setting[:default_proxy_download_policy]}")
        end
        Setting[:default_proxy_download_policy]
      end
    end
  end
end
