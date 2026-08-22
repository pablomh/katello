module Actions
  module Pulp3
    module CapsuleContent
      class RefreshDistribution < Pulp3::AbstractAsyncTask
        include Helpers::Presenter
        middleware.use Actions::Middleware::ExecuteIfContentsChanged

        def plan(repository, smart_proxy, options = {})
          plan_self(:repository_id => repository.id,
                    :smart_proxy_id => smart_proxy.id,
                    :options => options)
        end

        def invoke_external_task
          retried = false
          begin
            repo.backend_service(smart_proxy).with_mirror_adapter.refresh_distributions
          rescue StandardError => e
            # Concurrent create race: retry finds the distribution the other action just made.
            raise if retried || !::Katello::Pulp3::DistributionConflict.create_race?(e)
            retried = true
            retry
          end
        end

        private

        def repo
          @repo ||= ::Katello::Repository.find(input[:repository_id])
        end

        def smart_proxy
          @smart_proxy ||= super
        end
      end
    end
  end
end
