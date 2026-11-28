module Actions
  module Katello
    module ContentViewVersion
      # rubocop:disable Metrics/ClassLength
      class IncrementalUpdate < Actions::EntryAction
        include ::Katello::ContentViewHelper
        include Helpers::ContentViewAutoPublisher

        attr_accessor :new_content_view_version, :new_content_view_version_id

        HUMANIZED_TYPES = {
          ::Katello::Erratum::CONTENT_TYPE => "Errata",
          ::Katello::Rpm::CONTENT_TYPE => "Packages",
          ::Katello::Deb::CONTENT_TYPE => "Deb Packages",
        }.freeze

        def humanized_name
          _("Incremental Update")
        end

        # rubocop:disable Metrics/MethodLength
        # rubocop:disable Metrics/AbcSize
        # rubocop:disable Metrics/CyclomaticComplexity
        # rubocop:disable Metrics/PerceivedComplexity
        def plan(old_version, environments, options = {})
          dep_solve = options.fetch(:resolve_dependencies, false)
          description = options.fetch(:description, '')
          content = options.fetch(:content, {})
          new_components = options.fetch(:new_components, [])
          propagated_composite_cv_ids = options.fetch(:propagated_composite_cv_ids, [])

          is_composite = old_version.content_view.composite?
          all_components = is_composite ? calculate_components(old_version, new_components) : []

          action_subject(old_version.content_view)
          validate_environments(environments, old_version)
          validate_content_not_already_present(old_version, content) unless is_composite

          new_minor = old_version.content_view.versions.where(:major => old_version.major).maximum(:minor) + 1

          if is_composite
            sequence do
              publish_action = plan_action(::Actions::Katello::ContentView::Publish, old_version.content_view, description,
                          :major => old_version.major, :minor => new_minor,
                          :override_components => new_components, :skip_promotion => true)

              self.new_content_view_version_id = publish_action.content_view_version_id
              plan_self(:is_composite => true, :content_view_id => old_version.content_view.id,
                        :new_content_view_version_id => publish_action.content_view_version_id,
                        :environment_ids => environments.map(&:id), :user_id => ::User.current.id,
                        :history_id => publish_action.history_id,
                        :old_version => old_version.id,
                        :propagated_composite_cv_ids => propagated_composite_cv_ids)

              if old_version.environments.present?
                plan_action(::Actions::Katello::ContentView::Promote, publish_action.version,
                            old_version.environments, true, description)
              end
            end
          else
            self.new_content_view_version = old_version.content_view.create_new_version(old_version.major, new_minor, all_components)
            history = ::Katello::ContentViewHistory.create!(:content_view_version => new_content_view_version, :user => ::User.current.login,
                                                            :action => ::Katello::ContentViewHistory.actions[:publish],
                                                            :status => ::Katello::ContentViewHistory::IN_PROGRESS, :task => self.task,
                                                            :notes => description)

            copy_outputs = []
            repos_to_clone = repos_to_copy(old_version, new_components)

            sequence do
              repository_mapping = plan_action(ContentViewVersion::CreateRepos, new_content_view_version, repos_to_clone).repository_mapping
              separated_repo_map = separated_repo_mapping(repository_mapping, true)

              repos_to_clone.each do |source_repos|
                plan_action(Repository::CloneToVersion,
                            source_repos,
                            new_content_view_version,
                            repository_mapping[source_repos],
                            incremental: true)
              end

              # The clones already reuse their source's version, publication and index, so only the
              # repositories the selected units are copied into need further work.
              concurrence do
                [:pulp3_deb_multicopy, :pulp3_yum_multicopy].each do |mapping|
                  next if separated_repo_map[mapping].empty?
                  copy_output = plan_unit_copy(separated_repo_map[mapping], old_version, content, dep_solve)
                  copy_outputs << copy_output if copy_output
                end
              end

              plan_self(:content_view_id => old_version.content_view.id,
                        :new_content_view_version_id => self.new_content_view_version.id,
                        :environment_ids => environments.map(&:id), :user_id => ::User.current.id,
                        :history_id => history.id, :copy_action_outputs => copy_outputs,
                        :old_version => old_version.id,
                        :propagated_composite_cv_ids => propagated_composite_cv_ids)
              promote(new_content_view_version, environments)
            end
          end
        end

        def pulp3_content_mapping(content)
          units = ::Katello::Erratum.with_identifiers(content[:errata_ids]) +
            ::Katello::Deb.with_identifiers(content[:deb_ids]) +
            ::Katello::Rpm.with_identifiers(content[:package_ids])
          unit_map = { :errata => [], :debs => [], :rpms => [] }
          units.each do |unit|
            case unit.class.name
            when "Katello::Erratum"
              unit_map[:errata] << unit.id
            when "Katello::Deb"
              unit_map[:debs] << unit.id
            when "Katello::Rpm"
              unit_map[:rpms] << unit.id
            end
          end
          unit_map
        end

        # Copies the selected units into the clones holding them, then republishes the clones the copy
        # changed.
        def plan_unit_copy(repo_map, old_version, content, dep_solve)
          unit_map = pulp3_content_mapping(content)
          return if unit_map.values.flatten.empty?

          # Dependency solving can pull units into a repository that holds none of the selected ones.
          extended_repo_mapping = pulp3_repo_mapping(repo_map, old_version, dep_solve ? nil : unit_map)

          dest_repo_ids = extended_repo_mapping.values.pluck(:dest_repo).to_set
          copy_targets = repo_map.select { |_source_repos, dest_repo| dest_repo_ids.include?(dest_repo.id) }
          copy_output = nil
          seed_tasks = {}
          sequence do
            copy_targets.each do |source_repos, dest_repo|
              next unless seed_base?(dest_repo)
              seed = plan_action(Pulp3::Repository::CopyVersion, source_repos.first, SmartProxy.pulp_primary, dest_repo)
              seed_tasks[dest_repo.id.to_s] = seed.output[:pulp_tasks]
            end
            unless extended_repo_mapping.empty?
              copy_action = plan_action(Pulp3::Repository::MultiCopyUnits, extended_repo_mapping, unit_map,
                                        dependency_solving: dep_solve, incremental_update: true,
                                        seed_tasks: seed_tasks)
              copy_targets.each_value do |dest_repo|
                plan_action(Katello::Repository::MetadataGenerate, dest_repo,
                            contents_changed: copy_action.save_versions_output[:changed_repositories][dest_repo.id.to_s])
              end
              copy_output = copy_action.output
            end
          end
          copy_output
        end

        # The copy's version must directly follow one holding exactly the base, so its delta can be
        # indexed without range filters. A soft copy's base lives in the library's Pulp repository,
        # and a base older than the latest version is not what the copy's version follows.
        def seed_base?(dest_repo)
          return false if dest_repo.version_href.blank?
          dest_repo.soft_copy_of_library? ||
            dest_repo.version_href != dest_repo.backend_service(SmartProxy.pulp_primary).latest_version_href
        end

        def pulp3_repo_mapping(repo_mapping, old_version, selected_units = nil)
          pulp3_repo_mapping = {}
          repo_mapping.each do |source_repos, dest_repo|
            old_version_repo = old_version.repositories.archived.find_by(root_id: dest_repo.root_id)

            next if old_version_repo.version_href == old_version_repo.library_instance.version_href

            source_library_repo = source_repos.first.library_instance? ? source_repos.first : source_repos.first.library_instance
            next if selected_units && !holds_selected_units?(source_library_repo, selected_units)

            source_repos = [source_library_repo]
            if old_version_repo.version_href.nil?
              base_version = 0
            elsif old_version_repo.soft_copy_of_library?
              base_version = nil
            else
              base_version = old_version_repo.version_href.split("/")[-1].to_i
            end

            pulp3_repo_mapping[source_repos.map(&:id)] = { dest_repo: dest_repo.id, base_version: base_version }
          end
          pulp3_repo_mapping
        end

        def holds_selected_units?(repository, unit_map)
          ::Katello::RepositoryRpm.where(repository_id: repository.id, rpm_id: unit_map[:rpms]).exists? ||
            ::Katello::RepositoryErratum.where(repository_id: repository.id, erratum_id: unit_map[:errata]).exists? ||
            ::Katello::RepositoryDeb.where(repository_id: repository.id, deb_id: unit_map[:debs]).exists?
        end

        def repos_to_copy(old_version, new_components)
          old_version.archived_repos.map do |source_repo|
            components_repo_instances(source_repo, new_components)
          end
        end

        # For a given repo, find it's instances in both the new and old component versions.
        # This is necessary, since a composite content view may have components containing
        # the same repository within multiple component views and all of the source repos
        # will be needed to publish the new repo.
        def components_repo_instances(old_version_repo, new_component_versions)
          # Attempt to locate the repo instance in the new component versions
          new_repos = nil
          new_component_versions.map do |cvv|
            cvv.repositories.each do |component_repo|
              if component_repo.library_instance_id == old_version_repo.library_instance_id
                new_repos ||= []
                new_repos << component_repo
                break # each CVV can only have 1 repo with this instance id, so go to next CVV
              end
            end
          end

          # If we found it, we need to also locate the repo instance in the old component
          # versions, but omit the one changed by the new component version.
          if new_repos
            old_repos = nil
            old_version_repo.content_view_version.components.each do |component|
              component.archived_repos.each do |component_repo|
                # if the archived repo is not the same source as one of the new repos, include it
                new_repos.each do |new_repo|
                  if (new_repo.library_instance_id == component_repo.library_instance_id) &&
                      (new_repo.content_view.id != component_repo.content_view.id)
                    old_repos ||= []
                    old_repos << component_repo
                  end
                end
              end
            end
            new_repos.concat(old_repos) unless old_repos.blank?
            new_repos
          else
            [old_version_repo]
          end
        end

        def run
          version = ::Katello::ContentViewVersion.find(input[:new_content_view_version_id])
          if version.latest? && !version.content_view.composite?
            # Exclude composites that are already being updated via propagate to prevent duplicate publishes
            propagated_composite_cv_ids = input[:propagated_composite_cv_ids] || []
            auto_publish_ids = version.content_view.auto_publish_composites.pluck(:id) - propagated_composite_cv_ids
            unless auto_publish_ids.empty?
              output[:auto_publish_content_view_ids] = auto_publish_ids
              output[:auto_publish_content_view_version_id] = version.id
            end
          end

          content = { ::Katello::Erratum::CONTENT_TYPE => [],
                      ::Katello::Rpm::CONTENT_TYPE => [],
                      ::Katello::ModuleStream::CONTENT_TYPE => [],
                      ::Katello::Deb::CONTENT_TYPE => [],
                    }

          base_repos = ::Katello::ContentViewVersion.find(input[:old_version]).repositories
          new_repos = version.repositories

          copied = input[:copy_action_outputs].present? && input[:copy_action_outputs].last[:pulp_tasks].present?
          if input[:is_composite] || copied
            new_repos.each do |new_repo|
              matched_old_repo = base_repos.where(root_id: new_repo.root_id).first

              content[::Katello::Erratum::CONTENT_TYPE] += added_units(new_repo, matched_old_repo, :errata).pluck(:errata_id)
              added_units(new_repo, matched_old_repo, :module_streams).each do |module_stream|
                content[::Katello::ModuleStream::CONTENT_TYPE] <<
                  "#{module_stream.name}:#{module_stream.stream}:#{module_stream.version}"
              end
              content[::Katello::Rpm::CONTENT_TYPE] += added_units(new_repo, matched_old_repo, :rpms).map(&:nvra)
              content[::Katello::Deb::CONTENT_TYPE] += added_units(new_repo, matched_old_repo, :debs).map(&:nva)
            end
          end
          output[:added_units] = content
        end

        def finalize
          version = ::Katello::ContentViewVersion.find(input[:new_content_view_version_id])
          version.update_content_counts!
          version.add_applied_filters!
          generate_description(version, output[:added_units]) if version.description.blank?

          history = ::Katello::ContentViewHistory.find(input[:history_id])
          history.status = ::Katello::ContentViewHistory::SUCCESSFUL
          history.save!
        end

        # given a composite version, and a list of new components, calculate the list of all components for the new version
        def calculate_components(old_version, new_components)
          old_components = old_version.components.select do |component|
            !new_components.map(&:content_view_id).include?(component.content_view_id)
          end
          old_components + new_components
        end

        private

        def added_units(new_repo, old_repo, association)
          units = new_repo.public_send(association)
          return units unless old_repo
          units.where.not(id: old_repo.public_send(association).select(:id))
        end

        def generate_description(version, content)
          humanized_lines = []
          [::Katello::Erratum, ::Katello::Rpm].each do |content_type|
            unless content[content_type::CONTENT_TYPE].blank?
              humanized_lines << "#{HUMANIZED_TYPES[content_type::CONTENT_TYPE]}:"
              humanized_lines += content[content_type::CONTENT_TYPE].sort.map { |unit| "    #{unit}" }
            end
            humanized_lines << ''
          end

          version_history = version.history.publish.first
          if version_history.notes
            version_history.notes += "\n"
          else
            version_history.notes = ''
          end

          version_history.notes += humanized_lines.join("\n")
          version_history.save!
          version.save!
        end

        def validate_environments(to_environments, old_version)
          unless (to_environments - old_version.environments).empty?
            fail _("Content View Version %{id} not in all specified environments %{envs}") %
                     {:id => old_version.id, :envs => (to_environments - old_version.environments).map(&:name).join(',')}
          end
        end

        def validate_content_not_already_present(old_version, content)
          # Throw an error if all requested content already exists in the base content view version.
          return if content[:package_ids].blank? && content[:errata_ids].blank? && content[:deb_ids].blank?
          old_repo_ids = old_version.repositories.pluck(:id)

          # I'm using count on the assumption that incremental updates remain additive only. This will need to be
          # corrected if that assumption changes.
          if content[:package_ids].present?
            existing_count = ::Katello::RepositoryRpm.where(repository_id: old_repo_ids, rpm_id: content[:package_ids]).distinct.count(:rpm_id)
            return if existing_count < content[:package_ids].uniq.size
          end
          if content[:errata_ids].present?
            existing_count = ::Katello::RepositoryErratum.where(repository_id: old_repo_ids, erratum_id: content[:errata_ids]).distinct.count(:erratum_id)
            return if existing_count < content[:errata_ids].uniq.size
          end
          if content[:deb_ids].present?
            existing_count = ::Katello::RepositoryDeb.where(repository_id: old_repo_ids, deb_id: content[:deb_ids]).distinct.count(:deb_id)
            return if existing_count < content[:deb_ids].uniq.size
          end

          fail _("Incremental update will not add any new content. The specified content is already present.")
        end

        def promote(new_version, environments)
          plan_action(Katello::ContentView::Promote, new_version, environments, true, nil, true)
        end

        def plan_copy(action_class, source_repo, target_repo, clauses = nil, override_config = nil)
          plan_action(action_class,
                      :source_pulp_id => source_repo.pulp_id,
                      :target_pulp_id => target_repo.pulp_id,
                      :full_clauses => clauses,
                      :override_config => override_config,
                      :include_result => true)
        end
      end
    end
  end
end
