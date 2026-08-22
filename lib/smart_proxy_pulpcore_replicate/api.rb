require 'sinatra'
require 'openssl'
require 'json'
require 'smart_proxy_pulpcore_replicate/pulp_client'

module Proxy
  module PulpcoreReplicate
    class Api < ::Sinatra::Base
      helpers ::Proxy::Helpers

      post %r{/replicate/?} do
        content_type :json
        payload = JSON.parse(request.body.read)
        result = pulp_client.replicate(payload)
        status 202
        result.to_json
      rescue StandardError => e
        log_halt 500, e
      end

      post %r{/adopt/?} do
        content_type :json
        payload = JSON.parse(request.body.read)
        server = pulp_client.create_or_get_upstream_pulp(payload)
        paths = payload['adopt_base_paths'] || []
        pulp_client.adopt(server, paths, payload)
        { 'ok' => true, 'upstream_pulp_href' => server['pulp_href'] }.to_json
      rescue StandardError => e
        log_halt 500, e
      end

      private

      def pulp_client
        settings = Proxy::PulpcoreReplicate::Plugin.settings
        pulp_url = settings.pulp_url
        if pulp_url.nil? || pulp_url.to_s.empty? || pulp_url.to_s == 'https://localhost'
          pulp_url = default_pulp_url(settings)
        end
        PulpClient.new(
          pulp_url: pulp_url,
          api_root: settings.api_root,
          ssl_ca_file: settings.ssl_ca_file,
          ssl_client_cert: settings.ssl_client_cert_file,
          ssl_client_key: settings.ssl_client_key_file
        )
      end

      def default_pulp_url(settings)
        cert_file = settings.ssl_client_cert_file
        cn = nil
        if cert_file && File.exist?(cert_file)
          cn = OpenSSL::X509::Certificate.new(File.read(cert_file)).subject.to_a.assoc('CN')&.at(1)
        end
        host = cn.to_s.empty? ? 'localhost' : cn
        "https://#{host}"
      end
    end
  end
end
