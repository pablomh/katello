module Actions
  module Pulp3
    module CapsuleContent
      class Replicate < Pulp3::AbstractAsyncTask
        def plan(smart_proxy, options = {})
          plan_self(:smart_proxy_id => smart_proxy.id,
                    :organization_id => options.fetch(:organization).id,
                    :q_select => options[:q_select],
                    :repository_ids => Array(options[:repository_ids]),
                    :environment_id => options[:environment_id],
                    :content_view_id => options[:content_view_id])
        end

        def invoke_external_task
          ::Katello::Pulp3::Replication.assert_single_content_org!(repos, organization)
          result = ::Katello::Pulp3::Replication::ProxyClient.new(smart_proxy).replicate(
            upstream_name: ::Katello::Pulp3::Replication.upstream_name_for(organization),
            satellite_base_url: ::Katello::Pulp3::Replication.satellite_pulp_base_url,
            q_select: input[:q_select],
            stored_q_select: stored_q_select,
            force_sync: scoped_replicate?,
            client_cert: api_client_cert,
            client_key: api_client_key,
            ca_cert: ::Cert::Certs.ca_cert,
            policy: 'labeled',
            remote_download_policy: ::Katello::Pulp3::Replication.remote_download_policy(smart_proxy, repos),
            remote_settings: remote_settings,
            adopt_base_paths: adopt_base_paths,
            protected_base_paths: protected_base_paths,
            **::Katello::Pulp3::Replication.remote_credentials_for(organization)
          )
          transform_proxy_result(result)
        end

        def humanized_name
          _("Replicate content to smart proxy")
        end

        def rescue_strategy_for_self
          Dynflow::Action::Rescue::Skip
        end

        private

        def stored_q_select
          ::Katello::Pulp3::Replication.q_select_for(
            lifecycle_environments: smart_proxy.lifecycle_environments
          )
        end

        def api_client_cert
          File.read(::Cert::Certs.ssl_client_cert_filename)
        end

        def api_client_key
          File.read(::Cert::Certs.ssl_client_key_filename)
        end

        def scoped_replicate?
          input[:q_select].present?
        end

        def remote_settings
          {
            total_timeout: Setting[:sync_total_timeout],
            connect_timeout: Setting[:sync_connect_timeout_v2],
            sock_connect_timeout: Setting[:sync_sock_connect_timeout],
            sock_read_timeout: Setting[:sync_sock_read_timeout],
            rate_limit: Setting[:download_rate_limit],
          }.compact
        end

        def organization
          @organization ||= ::Organization.find(input[:organization_id])
        end

        def adopt_base_paths
          repos.map { |repo| ::Katello::Pulp3::Replication.distribution_path_for(repo) }
        end

        def protected_base_paths
          repos.reject { |repo| repo.root.unprotected || repo.docker? }.map do |repo|
            ::Katello::Pulp3::Replication.distribution_path_for(repo)
          end
        end

        def repos
          @repos ||= ::Katello::Repository.where(:id => Array(input[:repository_ids]))
        end

        def transform_proxy_result(result)
          return [] if result.blank?
          result = result.with_indifferent_access if result.respond_to?(:with_indifferent_access)
          task_group = result['task_group'] || result['pulp_href']
          if task_group
            [{'task_group' => task_group}]
          else
            []
          end
        end
      end
    end
  end
end
