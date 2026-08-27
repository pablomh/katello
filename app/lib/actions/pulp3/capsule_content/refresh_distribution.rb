module Actions
  module Pulp3
    module CapsuleContent
      class RefreshDistribution < Pulp3::AbstractAsyncTask
        def plan(repository, smart_proxy)
          plan_self(:repository_id => repository.id,
                    :smart_proxy_id => smart_proxy.id)
        end

        def invoke_external_task
          retried = false
          begin
            repo.backend_service(smart_proxy).with_mirror_adapter.refresh_distributions
          rescue StandardError => e
            # Concurrent create race raised synchronously here, not via rescue_external_task
            # below. StandardError is wide because each content type's Pulp client has its
            # own ApiError with no shared ancestor; create_race? is the real filter.
            raise if retried || !::Katello::Pulp3::DistributionConflict.create_race?(e)
            retried = true
            retry
          end
        end

        def rescue_external_task(error)
          # Same race, but surfaced as a failed task (202 then worker error) instead.
          if error.is_a?(::Katello::Errors::Pulp3Error) && !retried_distribution_refresh? &&
              ::Katello::Pulp3::DistributionConflict.create_race?(error)
            output[:retried_distribution_refresh] = true
            self.external_task = invoke_external_task
          else
            super
          end
        end

        private

        def repo
          @repo ||= ::Katello::Repository.find(input[:repository_id])
        end

        def smart_proxy
          @smart_proxy ||= super
        end

        def retried_distribution_refresh?
          output[:retried_distribution_refresh]
        end
      end
    end
  end
end
