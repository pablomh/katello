module Katello
  module Pulp3
    class SmartProxyMirrorRepository < SmartProxyRepository
      def initialize(smart_proxy)
        fail "Cannot use a central pulp smart proxy" if smart_proxy.pulp_primary?
        @smart_proxy = smart_proxy
      end

      def orphaned_repositories
        repo_map = {}

        smart_proxy_helper = ::Katello::SmartProxyHelper.new(smart_proxy)
        katello_repos = smart_proxy_helper.combined_repos_available_to_capsule
        pulp3_enabled_repo_types.each do |repo_type|
          api = repo_type.pulp3_api(smart_proxy)
          repos = api.list_all
          _, eligible_repos = partition_protected_orphan_cleanup(repos, 'repositories')
          inventory = ::Katello::Pulp3::Replication::CapsuleInventory.new(smart_proxy, katello_repos)
          known_names = inventory.known_names(api.distributions_list_all)
          repo_map[api] = eligible_repos.reject { |capsule_repo| inventory.known_object?(capsule_repo) || known_names.include?(capsule_repo.name) }
        end

        repo_map
      end

      def orphan_repository_versions
        repo_version_map = {}

        pulp3_enabled_repo_types.each do |repo_type|
          api = repo_type.pulp3_api(smart_proxy)
          _, eligible_repos = partition_protected_orphan_cleanup(api.list_all, 'repositories')
          orphan_version_hrefs = eligible_repos.collect do |pulp_repo|
            mirror_repo_versions = api.versions_list_for_repository(pulp_repo.pulp_href, ordering: ['-pulp_created'])
            version_hrefs = mirror_repo_versions.select { |repo_version| repo_version.number != 0 }.collect { |version| version.pulp_href }

            version_hrefs - [pulp_repo.latest_version_href]
          end
          repo_version_map[api] = orphan_version_hrefs.flatten.compact
        end

        repo_version_map
      end

      def report_misconfigured_repository_version(api, href)
        # Reasons for distributions distributing orphaned repository versions:
        # 1. The sync succeeded but Pulp did not update the publication (yum content)
        #    - Fix: completely resync the repository to the smart proxy (need to verify)
        # 2. The sync suceeded but metadata was not generated (non-yum content)
        #    - Fix: completely resync the repository on the smart proxy (need to verify)
        # 3. A repository, distribution, and publication was lost track of
        #    - Fix: same as 4
        # 4. Pulp content was modified outside of Katello
        #    - Fix: find repositories outside of Katello and delete them. Deleting the entire repo works and leaves an orphaned distribution.
        #        - If RemoveUnneededRepos goes first, this should be taken care of.
        # 5. An older repository version has a distribution, but the repository is not an orphan
        #    - Fix: delete the orphan distribution
        errors = []
        related_distributions = if api.repository_type.publications_api_class.present?
                                  publication_hrefs = api.publications_list_all(repository_version: href).map(&:pulp_href)
                                  # Searching distributions by publication isn't supported
                                  api.distributions_list_all.select { |dist| publication_hrefs.include? dist.publication }
                                else
                                  # Searching distributions by repository version isn't supported
                                  api.distributions_list_all.select { |dist| dist.repository_version == href }
                                end
        repositories_to_redistribute = ::Katello::Pulp3::Replication::CapsuleInventory.matching_repositories(related_distributions)
        if repositories_to_redistribute.present?
          warning = "Completely resync (skip metadata check) repositories with the following paths to the smart proxy with ID #{smart_proxy.id}: " \
                    "#{repositories_to_redistribute.map(&:relative_path).join(', ')}. " \
                    "Orphan cleanup is skipped for these repositories until they are fixed on smart proxy with ID #{smart_proxy.id}. " \
                    "Try `hammer capsule content synchronize --id #{smart_proxy.id} --skip-metadata-check 1 ...` using " \
                    "--repository-id with #{repositories_to_redistribute.map(&:id).join(', ')}."
          errors << warning
          Rails.logger.warn(warning)
        end
        Rails.logger.debug("Orphan cleanup error: investigate the version_href #{href} on the smart proxy with ID #{smart_proxy.id} " \
                            "and the related distributions #{related_distributions.map(&:pulp_href)}")
        Rails.logger.debug('It is likely that the related distributions are distributing an older version of the repository.')
        errors
      end

      # See app/services/katello/pulp3/smart_proxy_repository.rb#delete_orphan_repository_versions for foreman orphan cleanup
      def delete_orphan_repository_versions
        tasks = []
        errors = []
        orphan_repository_versions.each do |api, version_hrefs|
          version_hrefs.each do |href|
            tasks << api.repository_versions_api.delete(href)
          rescue => e
            if e.message.include?('Please update the necessary distributions first.')
              errors << report_misconfigured_repository_version(api, href)
            else
              raise e
            end
          end
        end
        { pulp_tasks: tasks.flatten, errors: errors.flatten }
      end

      def delete_orphan_repositories
        tasks = []

        orphaned_repositories.each do |api, pulp3_repo_list|
          tasks << pulp3_repo_list.collect do |repo|
            api.repositories_api.delete(repo.pulp_href)
          end
        end

        tasks.flatten!
      end

      def delete_orphan_distributions
        tasks = []
        # Built once and reused across repo_types: every repo's `root` (needed to
        # resolve replicable_type?/distribution_path_for) is preloaded in 2 queries
        # total instead of triggering one query per repository row, per repo_type.
        inventory = ::Katello::Pulp3::Replication::CapsuleInventory.new(smart_proxy, ::Katello::Repository.includes(:root))
        pulp3_enabled_repo_types.each do |repo_type|
          orphan_distributions(repo_type, inventory).each do |distribution|
            tasks << repo_type.pulp3_api(smart_proxy).delete_distribution(distribution.pulp_href)
          end
        end
        tasks
      end

      def orphan_distributions(repo_type, inventory)
        api = repo_type.pulp3_api(smart_proxy)
        api.distributions_list_all.select do |distribution|
          if self.class.orphan_cleanup_protected?(distribution)
            log_protected_orphan_cleanup('distributions', [distribution])
            false
          else
            self.class.orphan_distribution?(distribution, inventory)
          end
        end
      end

      def self.orphan_distribution?(distribution, inventory)
        !::Katello::Pulp3::Replication::CapsuleInventory.linked_to_repository?(distribution) ||
          !inventory.known_object?(distribution)
      end

      def delete_orphan_alternate_content_sources
        tasks = []
        known_acs_hrefs = []
        known_acss = smart_proxy.smart_proxy_alternate_content_sources
        known_acs_hrefs = known_acss.pluck(:alternate_content_source_href) if known_acss.present?

        if RepositoryTypeManager.enabled_repository_types['file']
          file_acs_api = ::Katello::Pulp3::Repository.api(smart_proxy, 'file').alternate_content_source_api
          orphan_file_acs_hrefs = file_acs_api.list.results.map(&:pulp_href) - known_acs_hrefs
          orphan_file_acs_hrefs.each do |orphan_file_acs_href|
            tasks << file_acs_api.delete(orphan_file_acs_href)
          end
        end
        if RepositoryTypeManager.enabled_repository_types['yum']
          yum_acs_api = ::Katello::Pulp3::Repository.api(smart_proxy, 'yum').alternate_content_source_api
          orphan_yum_acs_hrefs = yum_acs_api.list.results.map(&:pulp_href) - known_acs_hrefs
          orphan_yum_acs_hrefs.each do |orphan_yum_acs_href|
            tasks << yum_acs_api.delete(orphan_yum_acs_href)
          end
        end
        if RepositoryTypeManager.enabled_repository_types['deb']
          deb_acs_api = ::Katello::Pulp3::Repository.api(smart_proxy, 'deb').alternate_content_source_api
          orphan_deb_acs_hrefs = deb_acs_api.list.results.map(&:pulp_href) - known_acs_hrefs
          orphan_deb_acs_hrefs.each do |orphan_deb_acs_href|
            tasks << deb_acs_api.delete(orphan_deb_acs_href)
          end
        end
        tasks
      end

      def delete_orphan_remotes
        tasks = []
        smart_proxy_helper = ::Katello::SmartProxyHelper.new(smart_proxy)
        katello_repos = smart_proxy_helper.combined_repos_available_to_capsule
        acs_remotes = Katello::SmartProxyAlternateContentSource.pluck(:remote_href)
        pulp3_enabled_repo_types.each do |repo_type|
          api = repo_type.pulp3_api(smart_proxy)
          _, eligible_remotes = partition_protected_orphan_cleanup(api.remotes_list_all(smart_proxy), 'remotes')
          inventory = ::Katello::Pulp3::Replication::CapsuleInventory.new(smart_proxy, katello_repos)
          known_names = inventory.known_names(api.distributions_list_all)

          eligible_remotes.each do |remote|
            known = inventory.known_object?(remote) || known_names.include?(remote.name)
            if !known && !acs_remotes.include?(remote.pulp_href)
              tasks << api.delete_remote(remote.pulp_href)
            end
          end
        end
        tasks
      end
    end
  end
end
