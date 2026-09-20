require "pulpcore_client"

module Katello
  module Pulp3
    module Api
      class UpstreamPulp < Core
        def api_client
          @api_client ||= begin
            config = smart_proxy.pulp3_configuration(PulpcoreClient::Configuration)
            api_client_class(PulpcoreClient::ApiClient.new(config))
          end
        end

        def upstream_pulps_api
          @upstream_pulps_api ||= PulpcoreClient::UpstreamPulpsApi.new(api_client)
        end

        def find_by_name(name)
          upstream_pulps_api.list(name: name).results.first
        end

        def ensure_endpoint(profile)
          create_or_update(profile.name, profile.to_h)
        end

        def replicate(pulp_href, request)
          upstream_pulps_api.replicate(pulp_href, request.to_h)
        end

        delegate :adopt, to: :upstream_pulps_api

        private

        def create_or_update(name, attrs)
          existing = find_by_name(name)
          data = attrs.merge(name: name)
          if existing
            upstream_pulps_api.partial_update(existing.pulp_href, data) if needs_update?(existing, attrs)
            existing.pulp_href
          else
            begin
              upstream_pulps_api.create(data).pulp_href
            rescue PulpcoreClient::ApiError => e
              # unique_together(name, pulp_domain) race: another concurrent org-sync created it first
              raise e unless create_race?(e) && (winner = find_by_name(name))
              upstream_pulps_api.partial_update(winner.pulp_href, data) if needs_update?(winner, attrs)
              winner.pulp_href
            end
          end
        end

        # client_key/remote_client_key/username/password are write-only in pulpcore's
        # serializer and never come back on a read, so they can't be compared - a cert
        # change is the reliable signal a credential rotated, since Candlepin always
        # reissues cert+key together.
        WRITE_ONLY_FIELDS = [:client_key, :remote_client_key, :username, :password].freeze
        CREATE_RACE_PATTERN = /
          \bname\b.*?(must\ be\ unique | code=['"]unique) |
          already\ exists
        /imx

        def needs_update?(existing, attrs)
          attrs.any? do |field, value|
            next false if WRITE_ONLY_FIELDS.include?(field)

            !existing.respond_to?(field) || existing.public_send(field) != value
          end
        end

        def create_race?(error)
          message = [error&.message, error&.body].compact.join("\n")
          message.match?(CREATE_RACE_PATTERN)
        end
      end
    end
  end
end
