module Actions
  module Pulp3
    module CapsuleContent
      class RefreshAllDistributions < Actions::EntryAction
        def plan(smart_proxy, repos)
          repos = Array(repos).compact
          return if repos.empty?

          plan_self(:smart_proxy_id => smart_proxy.id,
                    :repository_ids => repos.map(&:id))
          repos.in_groups_of(Setting[:foreman_proxy_content_batch_size], false) do |repo_batch|
            concurrence do
              repo_batch.each do |repo|
                plan_action(RefreshDistribution, repo, smart_proxy)
              end
            end
          end
        end

        def humanized_name
          _("Refresh smart proxy distributions")
        end
      end
    end
  end
end
