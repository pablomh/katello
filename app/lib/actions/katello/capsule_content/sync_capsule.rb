module Actions
  module Katello
    module CapsuleContent
      class SyncCapsule < ::Actions::EntryAction
        execution_plan_hooks.use :update_content_counts, :on => :success
        def plan(smart_proxy, options = {})
          plan_self(:smart_proxy_id => smart_proxy.id,
                    :environment_id => options[:environment_id],
                    :content_view_id => options[:content_view_id],
                    :repository_id => options[:repository_id],
                    :skip_content_counts_update => options[:skip_content_counts_update])
          action_subject(smart_proxy)
          environment = options[:environment]
          content_view = options[:content_view]
          repository = options[:repository]
          skip_metadata_check = options.fetch(:skip_metadata_check, false)

          sequence do
            scoped = scoped_repositories(smart_proxy, environment, content_view, repository)
            replicable, fallback = partition_for_replication(smart_proxy, scoped)
            use_replicate = replicable.any?
            classic_repos = apply_history_skip(smart_proxy, use_replicate ? fallback : scoped, skip_metadata_check)

            return nil if replicable.empty? && classic_repos.empty?

            if environment.nil? && content_view.nil? && repository.nil?
              options[:repository_ids_list] = classic_repos.map(&:id)
            elsif use_replicate && classic_repos.any?
              options[:repository_ids_list] = classic_repos.map(&:id)
            end

            plan_classic_sync(smart_proxy, classic_repos, options, skip_metadata_check) if classic_repos.any?
            if use_replicate
              plan_replication(smart_proxy, replicable, options, environment, content_view)
              plan_pxe_fetch(smart_proxy, replicable)
            end
          end
        end

        def plan_replication(smart_proxy, repos, options, environment, content_view)
          concurrence do
            ::Katello::Pulp3::Replication.group_by_org(repos).each do |organization, org_repos|
              plan_action(Actions::Pulp3::CapsuleContent::Replicate,
                          smart_proxy,
                          organization: organization,
                          q_select: q_select_for(options),
                          repository_ids: org_repos.map(&:id),
                          environment_id: environment&.id || options[:environment_id],
                          content_view_id: content_view&.id || options[:content_view_id])
            end
          end
        end

        def plan_classic_sync(smart_proxy, repos, options, skip_metadata_check)
          if smart_proxy.has_feature?(SmartProxy::PULP3_FEATURE)
            plan_action(Actions::Pulp3::Orchestration::Repository::RefreshRepos, smart_proxy, options)
          end

          repos.in_groups_of(Setting[:foreman_proxy_content_batch_size], false) do |repo_batch|
            concurrence do
              repo_batch.each do |repo|
                if smart_proxy.pulp3_support?(repo)
                  plan_action(Actions::Pulp3::CapsuleContent::Sync,
                    repo, smart_proxy,
                    skip_metadata_check: skip_metadata_check)
                end
              end
            end

            plan_pxe_fetch(smart_proxy, repo_batch)
          end
        end

        def plan_pxe_fetch(smart_proxy, repos)
          concurrence do
            Array(repos).each do |repo|
              if repo.is_a?(::Katello::Repository) &&
                  repo.distribution_bootable? &&
                  repo.download_policy == ::Katello::RootRepository::DOWNLOAD_ON_DEMAND
                plan_action(Katello::Repository::FetchPxeFiles,
                            id: repo.id,
                            capsule_id: smart_proxy.id)
              end
            end
          end
        end

        def partition_for_replication(smart_proxy, repos)
          return [[], Array(repos)] unless ::Katello::Pulp3::Replication.capable?(smart_proxy)
          ::Katello::Pulp3::Replication.partition(repos)
        end

        def q_select_for(options)
          environment = options[:environment]
          content_view = options[:content_view]
          repository = options[:repository]
          if environment.nil? && content_view.nil? && repository.nil?
            # Full Capsule sync: omit per-request q_select so stored UpstreamPulp.q_select
            # is used and remove_missing runs. Do not PATCH stored q_select here.
            nil
          else
            ::Katello::Pulp3::Replication.q_select_for(
              environment: environment,
              content_view: content_view,
              repository: repository
            )
          end
        end

        def scoped_repositories(smart_proxy, environment, content_view, repository)
          smart_proxy_helper = ::Katello::SmartProxyHelper.new(smart_proxy)
          smart_proxy_helper.lifecycle_environment_check(environment, repository)
          if repository
            [repository]
          else
            smart_proxy_helper.repositories_available_to_capsule(environment, content_view).by_rpm_count
          end
        end

        def apply_history_skip(smart_proxy, repos, skip_metadata_check)
          repos = Array(repos).compact
          return repos if repos.empty?
          smart_proxy_helper = ::Katello::SmartProxyHelper.new(smart_proxy)
          if skip_metadata_check
            smart_proxy_helper.clear_smart_proxy_sync_histories(repos)
            return repos
          end
          skip = ::Katello::Repository.synced_on_capsule(smart_proxy)
          repos - skip
        end

        def update_content_counts(_execution_plan)
          if Setting[:automatic_content_count_updates] && !input[:skip_content_counts_update]
            smart_proxy = ::SmartProxy.unscoped.find(input[:smart_proxy_id])
            options = {environment_id: input[:environment_id], content_view_id: input[:content_view_id], repository_id: input[:repository_id]}
            ::ForemanTasks.async_task(::Actions::Katello::CapsuleContent::UpdateContentCounts, smart_proxy, options)
          else
            Rails.logger.info "Skipping content counts update as automatic content count updates are disabled. To enable automatic content count updates, set the 'automatic_content_count_updates' setting to true.
To update content counts manually, run the 'Update Content Counts' action."
          end
        end

        def resource_locks
          :link
        end

        def run
          smart_proxy = ::SmartProxy.unscoped.find(input[:smart_proxy_id])
          smart_proxy.sync_container_gateway
        end

        def rescue_strategy
          Dynflow::Action::Rescue::Skip
        end
      end
    end
  end
end
