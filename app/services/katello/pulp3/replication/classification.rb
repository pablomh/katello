module Katello
  module Pulp3
    module Replication
      module Classification
        # Containers remain on the classic path until Satellite's registry token flow
        # has a direct-upstream auth model that fits this service-to-service contract.
        REPLICABLE_TYPES = %w[yum].freeze

        def replicable_type?(repo)
          REPLICABLE_TYPES.include?(repo.content_type)
        end

        def protected_content?(repo)
          replicable_type?(repo) && !repo.root.unprotected
        end

        def partition(repos)
          Array(repos).partition { |repo| replicable_type?(repo) }
        end

        def replicable_repos_for(smart_proxy, repos, pulp3_support: nil)
          repos = Array(repos)
          return [[], repos] unless capable?(smart_proxy)

          pulp3_support ||= Hash.new { |hash, repo| hash[repo] = smart_proxy.pulp3_support?(repo) }
          supported = repos.select { |repo| pulp3_support[repo] }
          replicable, = partition(supported)
          unless protected_replicate_capable?(smart_proxy)
            protected_repos, replicable = replicable.partition { |repo| protected_content?(repo) }
            if protected_repos.any?
              Rails.logger.warn("Capsule #{smart_proxy.name} pulpcore #{pulpcore_version(smart_proxy) || 'unknown'} " \
                                 "lacks remote transport overrides for protected replicate; falling back to " \
                                 "classic sync for #{protected_repos.size} repository(ies).")
            end
          end
          [replicable, repos - replicable]
        end
      end
    end
  end
end
