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
          scoped_request = !(environment.nil? && content_view.nil? && repository.nil?)
          # Memoized so a repo's pulp3_support? (an uncached Feature lookup) is computed once
          # per plan, not once per call site (replicable_repos_for, plan_classic_sync,
          # plan_distribution_cutover all need it for the same repos).
          pulp3_support = Hash.new { |hash, repo| hash[repo] = smart_proxy.pulp3_support?(repo) }
          sequence do
            candidate_repos = scoped_repositories(smart_proxy, environment, content_view, repository)
            replicable, fallback = ::Katello::Pulp3::Replication.replicable_repos_for(smart_proxy, candidate_repos,
                                                                                       pulp3_support: pulp3_support)

            replicable = apply_replicate_history_skip(smart_proxy, replicable, skip_metadata_check, scoped_request)
            classic_repos = sort_by_rpm_count(apply_history_skip(smart_proxy, fallback, skip_metadata_check))
            return nil if replicable.empty? && classic_repos.empty?

            if environment.nil? && content_view.nil? && repository.nil?
              options[:repository_ids_list] = classic_repos.pluck(:id)
            end

            plan_sync_streams(smart_proxy, replicable, classic_repos, options, scoped_request, skip_metadata_check, pulp3_support)
          end
        end

        # Disjoint repo sets (yum via replicate() vs. everything else) with no
        # ordering dependency between them - run them concurrently instead of
        # forcing one to finish before the other starts.
        def plan_sync_streams(smart_proxy, replicable, classic_repos, options, scoped_request, skip_metadata_check, pulp3_support)
          concurrence do
            sequence do
              if replicable.any?
                plan_replication(smart_proxy, replicable, options, scoped_request)
                replicable.in_groups_of(Setting[:foreman_proxy_content_batch_size], false) do |repo_batch|
                  plan_pxe_fetch(smart_proxy, repo_batch)
                end
              end
            end

            sequence do
              if classic_repos.any?
                plan_classic_sync(smart_proxy, classic_repos, options, skip_metadata_check, pulp3_support)
                plan_distribution_cutover(smart_proxy, classic_repos, pulp3_support)
              end
            end
          end
        end

        def plan_replication(smart_proxy, repos, options, scoped_request)
          grouped = ::Katello::Pulp3::Replication.group_by_org_and_policy(smart_proxy, repos)
          policy_group_count_by_org = grouped.each_key.each_with_object(Hash.new(0)) do |(organization, _policy), memo|
            memo[organization] += 1
          end

          unless scoped_request
            policy_group_count_by_org.each do |organization, group_count|
              next unless group_count > 1

              Rails.logger.warn(
                "Capsule #{smart_proxy.name} has #{group_count} replicate policy groups for organization " \
                "#{organization.label}; disabling prune for those grouped replicate() runs to avoid " \
                "cross-pruning a shared UpstreamPulp endpoint."
              )
            end
          end

          concurrence do
            grouped.each do |(organization, remote_download_policy), org_repos|
              plan_action(Actions::Pulp3::CapsuleContent::Replicate, smart_proxy, organization,
                          force_sync: options.fetch(:force_sync, false), repository_ids: org_repos.map(&:id),
                          remote_download_policy: remote_download_policy,
                          prune: !scoped_request && policy_group_count_by_org[organization] == 1)
            end
          end
        end

        def plan_classic_sync(smart_proxy, repos, options, skip_metadata_check, pulp3_support)
          if smart_proxy.has_feature?(SmartProxy::PULP3_FEATURE)
            plan_action(Actions::Pulp3::Orchestration::Repository::RefreshRepos, smart_proxy, options)
          end

          repos.in_groups_of(Setting[:foreman_proxy_content_batch_size], false) do |repo_batch|
            concurrence do
              repo_batch.each do |repo|
                if pulp3_support[repo]
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

        def plan_distribution_cutover(smart_proxy, repos, pulp3_support)
          pulp3_repos = repos.select { |repo| pulp3_support[repo] }
          return if pulp3_repos.empty?

          plan_action(Actions::Pulp3::CapsuleContent::RefreshAllDistributions, smart_proxy, pulp3_repos)
        end

        def scoped_repositories(smart_proxy, environment, content_view, repository)
          smart_proxy_helper = ::Katello::SmartProxyHelper.new(smart_proxy)
          smart_proxy_helper.lifecycle_environment_check(environment, repository)
          if repository
            [repository]
          else
            smart_proxy_helper.repositories_available_to_capsule(environment, content_view)
          end
        end

        # by_rpm_count only benefits classic_sync's batching order - applying it to every
        # candidate repo before partitioning wastes a join+group query on repos that end up
        # routed to replicate(), which doesn't care about repo order.
        def sort_by_rpm_count(repos)
          repos = Array(repos).compact
          return repos if repos.size <= 1

          repos_by_id = repos.index_by(&:id)
          ::Katello::Repository.where(:id => repos_by_id.keys).by_rpm_count.pluck(:id).filter_map do |repo_id|
            repos_by_id[repo_id]
          end
        end

        def apply_history_skip(smart_proxy, repos, skip_metadata_check)
          repos = Array(repos).compact
          return repos if repos.empty?

          if skip_metadata_check
            ::Katello::SmartProxyHelper.new(smart_proxy).clear_smart_proxy_sync_histories(repos)
            return repos
          end

          synced_repo_ids = ::Katello::SmartProxySyncHistory.synced_repository_ids_for(smart_proxy, repos)
          repos.reject { |repo| synced_repo_ids.include?(repo.id) }
        end

        # Routine replicate runs now prune against the full assigned repo set, so
        # skipping a subset there would incorrectly make managed repos look absent.
        # Scoped replicate runs set prune=false, so history-based omission is only
        # safe for those selective runs.
        def apply_replicate_history_skip(smart_proxy, repos, skip_metadata_check, scoped_request)
          if skip_metadata_check
            ::Katello::SmartProxyHelper.new(smart_proxy).clear_smart_proxy_sync_histories(Array(repos))
            return Array(repos)
          end
          return Array(repos) unless scoped_request

          apply_history_skip(smart_proxy, repos, false)
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
