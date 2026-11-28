module Actions
  module Pulp3
    module Repository
      class SaveVersions < Pulp3::Abstract
        def plan(repository_ids, options)
          plan_self(:repository_ids => repository_ids, :tasks => options[:tasks],
                    :additive_copy => options.fetch(:additive_copy, false),
                    :seed_tasks => options.fetch(:seed_tasks, {}))
        end

        def run
          if input[:additive_copy]
            save_copied_versions
          else
            save_latest_versions
          end
        end

        def save_copied_versions
          output.merge!(contents_changed: false, updated_repositories: [], changed_repositories: {})
          created_hrefs = Array(input[:tasks]).flat_map { |task| Array(task[:created_resources]) }
          find_repositories(input[:repository_ids]).each { |repo| save_copied_version(repo, created_hrefs) }
        end

        def save_latest_versions
          return if input[:tasks].empty?
          version_hrefs = input[:tasks].last[:created_resources]
          repositories = find_repositories(input[:repository_ids])

          output.merge!(contents_changed: false, updated_repositories: [])
          repositories.each do |repo|
            repo_backend_service = repo.backend_service(SmartProxy.pulp_primary)
            if repo.version_href
              # Chop off the version number to compare base repo strings
              unversioned_href = repo.version_href[0..-2].rpartition('/').first
              # Could have multiple version_hrefs for the same repo depending on the copy task
              new_version_hrefs = version_hrefs.collect do |version_href|
                version_href if unversioned_href == version_href[0..-2].rpartition('/').first
              end

              new_version_hrefs.compact!
              if new_version_hrefs.size > 1
                # Find latest version_href by its version number
                new_version_href = version_map(new_version_hrefs).max_by { |_href, version| version }.first
              else
                new_version_href = new_version_hrefs.first
              end

              # Successive incremental updates won't generate a new repo version, so fetch the latest Pulp 3 repo version
              new_version_href ||= latest_version_href(repo_backend_service)
            else
              new_version_href = latest_version_href(repo_backend_service)
            end

            unless new_version_href == repo.version_href
              version = repo_backend_service.api.repository_versions_api.read(new_version_href, {fields: 'prn'})
              repo.update(version_href: new_version_href, version_prn: version.prn)
              repo.index_content
              output[:contents_changed] = true
              output[:updated_repositories] << repo.id
            end
          end
        end

        # The copy built each new version on the repository's saved version, so a repository the
        # copy created no version for is unchanged, and the saved version's associations only need
        # the difference applied.
        def save_copied_version(repo, created_hrefs)
          repo_backend_service = repo.backend_service(SmartProxy.pulp_primary)
          repository_href = repo_backend_service.repository_reference&.repository_href
          created = repository_href ? created_hrefs.select { |href| href.start_with?(repository_href) }.uniq : []
          output[:changed_repositories][repo.id.to_s] = created.any?
          return if created.empty?

          new_version_href = created.max_by { |href| href.split('/')[-1].to_i }
          previous_version_href = repo.version_href
          previous_version_prn = repo.version_prn
          version = repo_backend_service.api.repository_versions_api.read(new_version_href, {fields: 'prn'})
          repo.update(version_href: new_version_href, version_prn: version.prn)
          begin
            repo.index_content(changed_from: seed_version_href(repo, new_version_href) || previous_version_href)
          rescue StandardError
            # A retry only indexes a repository whose version changed.
            repo.update_columns(version_href: previous_version_href, version_prn: previous_version_prn)
            raise
          end
          output[:contents_changed] = true
          output[:updated_repositories] << repo.id
        end

        # A seed holds exactly the content the saved version's associations describe, so a copy
        # version right after it is indexed as a single-step delta.
        def seed_version_href(repo, new_version_href)
          seed_tasks = (input[:seed_tasks] || {})[repo.id.to_s]
          return if seed_tasks.blank?

          seed_href = ::Katello::Pulp3::Task.version_href(seed_tasks)
          seed_href if ::Katello::Pulp3::Repository.next_version?(seed_href, new_version_href)
        end

        def version_map(version_hrefs)
          version_map = {}
          version_hrefs.each do |href|
            version_map[href] = href.split("/")[-1].to_i
          end
          version_map
        end

        def latest_version_href(repo_backend_service)
          repo_backend_service.latest_version_href
        end

        def find_repositories(repository_ids)
          repository_ids.collect do |repo_id|
            if repo_id.is_a?(Hash)
              ::Katello::Repository.find(repo_id.with_indifferent_access[:id])
            else
              ::Katello::Repository.find(repo_id)
            end
          end
        end
      end
    end
  end
end
