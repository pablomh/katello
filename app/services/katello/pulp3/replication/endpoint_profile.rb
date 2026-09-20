module Katello
  module Pulp3
    module Replication
      class EndpointProfile
        attr_reader :organization

        def initialize(organization)
          @organization = organization
        end

        def name
          Replication.upstream_name_for(organization)
        end

        def to_h
          ueber_cert = ::Cert::Certs.ueber_cert(organization)
          ca_cert = ::Cert::Certs.ca_cert

          {
            base_url: Replication.primary_pulp_base_url,
            api_root: Replication.primary_pulp_api_root,
            policy: 'labeled',
            ca_cert: ca_cert,
            tls_validation: true,
          }.merge(
            Replication.upstream_api_credentials_for(ueber_cert),
            Replication.remote_transport_for(ueber_cert, ca_cert),
            Replication.upstream_remote_settings
          )
        end
      end
    end
  end
end
