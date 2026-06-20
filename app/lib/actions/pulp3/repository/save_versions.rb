module Actions
  module Pulp3
    module Repository
      class SaveVersions < Pulp3::Abstract
        def plan(repository_ids, options)
          plan_self(:repository_ids => repository_ids,
                    :tasks => options[:tasks],
                    :repo_context => options[:repo_context],
                    :unit_map => options[:unit_map])
        end

        def run
          return if input[:tasks].empty?
          version_hrefs = input[:tasks].last[:created_resources]
          repositories = find_repositories(input[:repository_ids])

          output.merge!(contents_changed: false, updated_repositories: [])
          repositories.each do |repo|
            repo_context = repo_context_for(repo)
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
              index_updated_repository(repo, repo_context)
              output[:contents_changed] = true
              output[:updated_repositories] << repo.id
            end
          end
        end

        def version_map(version_hrefs)
          version_map = {}
          version_hrefs.each do |href|
            version_map[href] = href.split("/")[-1].to_i
          end
          version_map
        end

        def latest_version_href(repo_backend_service)
          repo_backend_service.api.repositories_api.
            read(repo_backend_service.repository_reference.repository_href).latest_version_href
        end

        def repo_context_for(repo)
          Array(input[:repo_context]).map(&:with_indifferent_access).find do |context|
            context[:dest_repo_id].to_i == repo.id
          end || {}
        end

        def delta_content_hrefs_by_type
          @delta_content_hrefs_by_type ||= begin
            {
              rpm: ::Katello::Rpm.where(id: Array(input.dig(:unit_map, :rpms))).pluck(:pulp_id),
              erratum: if Array(input.dig(:unit_map, :errata)).empty?
                         []
                       else
                         ::Katello::RepositoryErratum.joins("inner join katello_errata on katello_repository_errata.erratum_id = katello_errata.id")
                           .where("katello_errata.id in (?)", Array(input.dig(:unit_map, :errata))).pluck(:erratum_pulp3_href)
                       end,
              deb: ::Katello::Deb.where(id: Array(input.dig(:unit_map, :debs))).pluck(:pulp_id)
            }.with_indifferent_access
          end
        end

        def index_updated_repository(repo, repo_context)
          base_repository_id = repo_context[:base_repository_id]
          source_repository_ids = Array(repo_context[:source_repository_ids]).map(&:to_i)
          delta_hrefs = delta_content_hrefs_by_type
          if base_repository_id.present? && source_repository_ids.size == 1 && delta_hrefs.values.any?(&:present?)
            base_repository = ::Katello::Repository.find(base_repository_id)
            delta_source_repository = ::Katello::Repository.find(source_repository_ids.first)
            repo.copy_indexed_data(base_repository)
            repo.merge_filtered_indexed_data(delta_source_repository, delta_hrefs)
            repo.update!(last_indexed: DateTime.now)
          else
            repo.index_content
          end
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
