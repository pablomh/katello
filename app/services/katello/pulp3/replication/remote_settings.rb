module Katello
  module Pulp3
    module Replication
      module RemoteSettings
        # Current direct-upstream deployments still reuse the org ueber cert for upstream
        # API access because there is no separate API principal wired yet. Keep this
        # isolated from remote content credentials so the credential split is explicit.
        def upstream_api_credentials_for(ueber_cert)
          { :client_cert => ueber_cert[:cert], :client_key => ueber_cert[:key] }
        end

        def remote_credentials_for(ueber_cert)
          { :remote_client_cert => ueber_cert[:cert], :remote_client_key => ueber_cert[:key] }
        end

        def remote_transport_for(ueber_cert, ca_cert)
          { :remote_ca_cert => ca_cert, :remote_tls_validation => true }.merge(remote_credentials_for(ueber_cert))
        end

        def effective_remote_download_policy(smart_proxy, repo)
          policy = smart_proxy.download_policy
          return policy unless policy.to_s == ::SmartProxy::DOWNLOAD_INHERIT

          repo.root&.download_policy || Setting[:default_proxy_download_policy]
        end

        def upstream_remote_settings
          {
            :total_timeout => Setting[:sync_total_timeout],
            :connect_timeout => Setting[:sync_connect_timeout_v2],
            :sock_connect_timeout => Setting[:sync_sock_connect_timeout],
            :sock_read_timeout => Setting[:sync_sock_read_timeout],
            :rate_limit => Setting[:download_rate_limit],
          }.compact
        end
      end
    end
  end
end
