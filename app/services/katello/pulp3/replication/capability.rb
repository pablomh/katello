module Katello
  module Pulp3
    module Replication
      module Capability
        MIN_PULPCORE_VERSION = Gem::Version.new('3.113.0')
        MIN_REMOTE_TRANSPORT_VERSION = Gem::Version.new('3.117.0')

        def capsule_enabled?
          Setting[:pulp_replicate_capsule_sync]
        end

        def capable?(smart_proxy)
          return false unless capsule_enabled?
          return false unless smart_proxy&.has_feature?(::SmartProxy::PULP3_FEATURE)
          pulpcore_version_ok?(smart_proxy)
        end

        def protected_replicate_capable?(smart_proxy)
          version = pulpcore_version(smart_proxy)
          version && version >= MIN_REMOTE_TRANSPORT_VERSION
        rescue StandardError => e
          Rails.logger.debug("Could not determine protected replicate support for #{smart_proxy&.name}: #{e.message}")
          false
        end

        def pulpcore_version_ok?(smart_proxy)
          version = pulpcore_version(smart_proxy)
          version && version >= MIN_PULPCORE_VERSION
        rescue StandardError => e
          Rails.logger.debug("Could not determine pulpcore version for #{smart_proxy&.name}: #{e.message}")
          false
        end

        def pulpcore_version(smart_proxy)
          cached = smart_proxy.instance_variable_get(:@_katello_pulpcore_version)
          return cached if smart_proxy.instance_variable_defined?(:@_katello_pulpcore_version)

          status = smart_proxy.ping_pulp3
          versions = status['versions'] || status[:versions] || []
          core = versions.find { |entry| %w[core pulpcore].include?(entry['component'] || entry[:component]) }
          version = if core
                      raw = (core['version'] || core[:version]).to_s
                      numeric = raw[/\d+\.\d+\.\d+/]
                      Gem::Version.new(numeric) if numeric
                    end
          smart_proxy.instance_variable_set(:@_katello_pulpcore_version, version)
          version
        end
      end
    end
  end
end
