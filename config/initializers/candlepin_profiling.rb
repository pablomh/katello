# Opt-in instrumentation for measuring Candlepin HTTP traffic and DB access
# during a registration load test.
#
# This file is designed to be the *first* commit applied to any branch being
# benchmarked, including current master (the baseline) and branches that
# change the Candlepin transport. It only hooks stable, public APIs that
# exist on both:
#   - RestClient::Request#execute, the single choke point every RestClient-
#     driven Candlepin call goes through today, and continues to go through
#     for any non-pooled/fallback traffic on branches that add pooling.
#   - Net::HTTP::Persistent#request, the choke point for pooled traffic on
#     branches that add it. On master this gem isn't loaded, so this hook
#     is skipped entirely and contributes nothing - the RestClient hook
#     alone captures 100% of Candlepin traffic there.
#   - ActiveSupport::Notifications "sql.active_record", Rails' own stable
#     instrumentation hook, unrelated to any Katello-internal code shape.
#
# Enable with:      KATELLO_CANDLEPIN_PROFILING=1
# Dump a report:    rake katello:candlepin_profiling:report
# Reset counters:   rake katello:candlepin_profiling:reset
#
# Zero overhead when the env var isn't set: nothing in this file runs.

if %w[1 true yes].include?(ENV['KATELLO_CANDLEPIN_PROFILING'].to_s.downcase)
  module Katello
    module CandlepinProfiling
      Bucket = Struct.new(:requests, :total_seconds) do
        def initialize
          super(0, 0.0)
        end
      end

      class << self
        def buckets
          @buckets ||= Hash.new { |h, k| h[k] = Bucket.new }
        end

        def mutex
          @mutex ||= Mutex.new
        end

        def record(bucket, seconds)
          mutex.synchronize do
            b = buckets[bucket]
            b.requests += 1
            b.total_seconds += seconds
          end
        end

        def reset!
          mutex.synchronize { buckets.clear }
        end

        def report
          mutex.synchronize do
            rows = buckets.map do |name, b|
              avg_ms = b.requests.zero? ? 0 : (b.total_seconds / b.requests * 1000).round(2)
              { bucket: name, count: b.requests, total_ms: (b.total_seconds * 1000).round(2), avg_ms: avg_ms }
            end
            rows.sort_by { |r| -r[:total_ms] }
          end
        end

        def log_report
          Rails.logger.info(
            "[candlepin_profiling] " +
            report.map { |r| "#{r[:bucket]}: count=#{r[:count]} total_ms=#{r[:total_ms]} avg_ms=#{r[:avg_ms]}" }.join(" | ")
          )
        end

        # Only local Candlepin traffic is tracked - upstream Candlepin (manifest
        # import/refresh) hits a different host and is intentionally excluded so
        # it doesn't dilute the registration-path signal this is built to measure.
        def candlepin_host?(host)
          return false if host.blank?

          @candlepin_host ||= begin
            URI.parse(SETTINGS.dig(:katello, :candlepin, :url).to_s).host
          rescue StandardError
            nil
          end

          host == @candlepin_host
        end
      end
    end
  end

  module Katello::CandlepinProfiling::RestClientHook
    def execute(&block)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super
    ensure
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      if Katello::CandlepinProfiling.candlepin_host?(uri&.host)
        Katello::CandlepinProfiling.record(:candlepin_http_request, elapsed)
        Katello::CandlepinProfiling.record(:candlepin_http_request_restclient, elapsed)
      end
    end
  end
  RestClient::Request.prepend(Katello::CandlepinProfiling::RestClientHook)

  # net-http-persistent is only ever require'd lazily (inside the pooled
  # transport, on branches that have it), not at boot - so `defined?` alone
  # is not reliable here regardless of eager_load timing. Try to load it
  # explicitly; on master (or any branch without the gem) this just raises
  # LoadError and we fall back to RestClient-only measurement.
  begin
    require 'net/http/persistent'
  rescue LoadError
    Rails.logger.info("[candlepin_profiling] net-http-persistent not available, measuring RestClient traffic only")
  end

  if defined?(Net::HTTP::Persistent)
    module Katello::CandlepinProfiling::PersistentHook
      def request(uri, req = nil, &block)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        super
      ensure
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        if Katello::CandlepinProfiling.candlepin_host?(uri&.host)
          Katello::CandlepinProfiling.record(:candlepin_http_request, elapsed)
          Katello::CandlepinProfiling.record(:candlepin_http_request_pooled, elapsed)
        end
      end
    end
    Net::HTTP::Persistent.prepend(Katello::CandlepinProfiling::PersistentHook)
  end

  ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
    event = ActiveSupport::Notifications::Event.new(*args)
    next if event.payload[:name] == "SCHEMA" || event.payload[:cached]

    Katello::CandlepinProfiling.record(:db_query, event.duration / 1000.0)
  end

  at_exit { Katello::CandlepinProfiling.log_report }

  Rails.logger.info("[candlepin_profiling] enabled - dump with `rake katello:candlepin_profiling:report`")
end
