# Opt-in instrumentation for comparing capsule sync approaches (classic vs. replicate()).
# Only loaded/prepended when KATELLO_PROFILE_CAPSULE_SYNC is set at boot - see
# lib/katello/engine.rb and lib/katello/tasks/profile_capsule_sync.rake.
#
# Every Pulp3 API service class (Yum, Docker, File, UpstreamPulp, ContentGuard, ...)
# routes through Core#api_client_class before returning a usable client, but each one
# returns an instance of a *different* generated `*Client::ApiClient` class (one per
# Pulp plugin) - there's no single shared class to prepend onto ahead of time. Instead,
# wrap the one shared chokepoint (api_client_class) and singleton-prepend the returned
# instance so every generated client, regardless of which plugin gem it comes from, gets
# its outbound call counted.
module Katello
  module Pulp3
    module Api
      module CoreProfiling
        module CallApiInstrumentation
          def call_api(*args, **kwargs)
            start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            super
          ensure
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
            Katello::Pulp3::Api::CoreProfiling.record_call(elapsed)
          end
        end

        def api_client_class(client)
          instrumented_client = super
          instrumented_client.singleton_class.prepend(CallApiInstrumentation) if instrumented_client.respond_to?(:call_api)
          instrumented_client
        end

        def self.record_call(elapsed)
          counter = current_counter
          counter[:count] += 1
          counter[:time] += elapsed
        end

        # Thread-scoped so concurrent sibling actions (e.g. inside a `concurrence` block,
        # each running on its own Dynflow worker thread) don't cross-attribute API calls.
        def self.current_counter
          Thread.current[:katello_profiling_api_calls] ||= {count: 0, time: 0.0}
        end

        def self.reset_current_counter
          Thread.current[:katello_profiling_api_calls] = {count: 0, time: 0.0}
        end
      end
    end
  end
end
