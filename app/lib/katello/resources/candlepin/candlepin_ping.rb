module Katello
  module Resources
    module Candlepin
      class CandlepinPing < CandlepinResource
        CACHE_KEY = 'katello/candlepin_status_response'.freeze
        CACHE_TTL = 30.seconds

        class << self
          # Fetch Candlepin status.
          # By default serves from cache when warm, falling back to Candlepin
          # on a cold miss and writing the result. Pass force: true to bypass
          # the cache and always fetch fresh — used by health-check callers
          # that need an authoritative current status.
          def ping(force: false)
            cache_miss = false
            result = Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL, force: force) do
              cache_miss = true
              ::Foreman::Logging.logger('registration').debug "rhsm_status cache=MISS"
              response = get('/candlepin/status').body
              JSON.parse(response).with_indifferent_access
            end
            ::Foreman::Logging.logger('registration').debug "rhsm_status cache=HIT" unless cache_miss
            result
          end

          # Returns true if Candlepin is in NORMAL mode.
          # Uses the cache populated by server_status so the pre-flight check
          # is a free Redis read when the cache is warm. Falls back to a direct
          # Candlepin ping on a cold miss and writes the result to cache.
          def ok?
            ping['mode'] == 'NORMAL'
          end
        end
      end
    end
  end
end
