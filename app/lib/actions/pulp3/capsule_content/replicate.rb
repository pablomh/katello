module Actions
  module Pulp3
    module CapsuleContent
      class Replicate < Pulp3::AbstractAsyncTask
        include ::Actions::Helpers::SmartProxySyncHistoryHelper

        def plan(smart_proxy, organization, options = {})
          plan_self(:smart_proxy_id => smart_proxy.id,
                    :organization_id => organization.id,
                    :force_sync => options.fetch(:force_sync, false),
                    :repository_ids => options[:repository_ids],
                    :remote_download_policy => options[:remote_download_policy],
                    :prune => options.fetch(:prune, true))
        end

        def invoke_external_task
          api = ::Katello::Pulp3::Api::UpstreamPulp.new(smart_proxy)
          pulp_href = ::Katello::Pulp3::Replication.ensure_upstream_pulp!(api, organization)
          response = api.replicate(pulp_href, replication_request)
          self.external_task = [{ 'task_group' => response.task_group }]
        end

        def humanized_name
          _("Replicate content to smart proxy")
        end

        def rescue_strategy_for_self
          Dynflow::Action::Rescue::Skip
        end

        private

        def organization
          @organization ||= ::Organization.find(input[:organization_id])
        end

        def repos
          @repos ||= ::Katello::Repository.includes(:root => :product,
                                                    :environment => :organization,
                                                    :content_view_version => :content_view).
            where(:id => Array(input[:repository_ids]))
        end

        def protected_base_paths
          repos.select { |repo| ::Katello::Pulp3::Replication.protected_content?(repo) }.map do |repo|
            ::Katello::Pulp3::Replication.distribution_path_for(smart_proxy, repo)
          end
        end

        def content_guard_href
          return if protected_base_paths.empty?

          @content_guard_href ||= ::Katello::Pulp3::Api::ContentGuard.new(smart_proxy).refresh&.pulp_href
        end

        def replication_request
          ::Katello::Pulp3::Replication::Request.new(
            repository_ids: input[:repository_ids],
            force_sync: input[:force_sync],
            prune: input[:prune],
            remote_policy: input[:remote_download_policy],
            protected_base_paths: protected_base_paths,
            content_guard_href: content_guard_href
          )
        end
      end
    end
  end
end
