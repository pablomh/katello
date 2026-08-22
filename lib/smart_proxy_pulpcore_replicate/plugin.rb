# Foreman Proxy plugin: Capsule-local UpstreamPulp.replicate().
# Loaded by foreman-proxy, not by Katello. Package separately later;
# Katello only requires lib/proxy_api/pulpcore_replicate.rb.
# Satellite never POSTs /pulp/api/v3/upstream-pulps/ at a Capsule with its own Ruby gems (SAT-39084).
module Proxy
  module PulpcoreReplicate
    class Plugin < ::Proxy::Plugin
      plugin :pulpcore_replicate, '1.0.0'

      default_settings :enabled => true,
                       :pulp_url => 'https://localhost',
                       :api_root => '/pulp/',
                       :ssl_ca_file => '/etc/foreman-proxy/foreman_ssl_ca.pem',
                       :ssl_client_cert_file => '/etc/foreman-proxy/foreman_ssl_cert.pem',
                       :ssl_client_key_file => '/etc/foreman-proxy/foreman_ssl_key.pem'

      http_rackup_path File.expand_path('config.ru', __dir__)
      https_rackup_path File.expand_path('config.ru', __dir__)
    end
  end
end
