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
# Puma runs multiple worker processes, each with its own memory, and the
# reporting rake task runs in yet another separate process - so counters
# can't just live in a local Hash. They accumulate locally per-process
# (zero network cost in the hot path, which matters most for db_query:
# a single registration can issue 1000+ queries) and flush the accumulated
# delta to Redis periodically, since Redis is already this app's cache
# backend. Every worker and the reporting task then read the same shared,
# eventually-consistent totals.
#
# Enable with:      KATELLO_CANDLEPIN_PROFILING=1
# Dump a report:    rake katello:candlepin_profiling:report
# Reset counters:   rake katello:candlepin_profiling:reset
#
# Zero overhead when the env var isn't set: nothing in this file runs.

if %w[1 true yes].include?(ENV['KATELLO_CANDLEPIN_PROFILING'].to_s.downcase)
  module Katello
    module CandlepinProfiling
      BUCKETS = [:candlepin_http_request, :candlepin_http_request_restclient, :candlepin_http_request_pooled, :db_query].freeze
      FLUSH_INTERVAL_SECONDS = 2

      Bucket = Struct.new(:requests, :total_seconds) do
        def initialize
          super(0, 0.0)
        end
      end

      class << self
        def record(bucket, seconds)
          local_mutex.synchronize do
            b = local_buckets[bucket]
            b.requests += 1
            b.total_seconds += seconds
          end
          flush! if due_for_flush?
        end

        def reset!
          local_mutex.synchronize { local_buckets.clear }
          BUCKETS.each { |bucket| redis.del(count_key(bucket), seconds_key(bucket)) }
        rescue StandardError => e
          Rails.logger.debug { "[candlepin_profiling] reset failed: #{e.class}: #{e.message}" }
        end

        # Flushes this process's locally-accumulated deltas into the shared
        # Redis counters. Safe to call from any process, including a
        # reporting rake task (a no-op there, since it has nothing local
        # to flush) - the point is that live Puma workers call this
        # periodically so their totals are visible to everyone else.
        def flush!
          deltas = local_mutex.synchronize do
            @last_flush_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            snapshot = local_buckets.dup
            local_buckets.clear
            snapshot
          end

          deltas.each do |bucket, b|
            next if b.requests.zero?

            redis.pipelined do |pipeline|
              pipeline.incrby(count_key(bucket), b.requests)
              pipeline.incrbyfloat(seconds_key(bucket), b.total_seconds)
            end
          end
        rescue StandardError => e
          Rails.logger.debug { "[candlepin_profiling] flush failed: #{e.class}: #{e.message}" }
        end

        def report
          flush!
          rows = BUCKETS.filter_map do |bucket|
            count = redis.get(count_key(bucket)).to_i
            next if count.zero?

            total_ms = redis.get(seconds_key(bucket)).to_f * 1000
            { bucket: bucket, count: count, total_ms: total_ms.round(2), avg_ms: (total_ms / count).round(2) }
          end
          rows.sort_by { |r| -r[:total_ms] }
        rescue StandardError => e
          Rails.logger.debug { "[candlepin_profiling] report failed: #{e.class}: #{e.message}" }
          []
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
        # Matches on host and port, not host alone: other RestClient-speaking
        # services (e.g. Pulp's content app) commonly share "localhost" with
        # Candlepin in an all-in-one deployment.
        def candlepin_request?(uri)
          return false if uri.nil?

          [uri.host, uri.port] == candlepin_endpoint
        end

        def candlepin_endpoint
          @candlepin_endpoint ||= begin
            uri = URI.parse(SETTINGS.dig(:katello, :candlepin, :url).to_s)
            [uri.host, uri.port]
          rescue StandardError
            nil
          end
        end

        private

        def local_buckets
          @local_buckets ||= Hash.new { |h, k| h[k] = Bucket.new }
        end

        def local_mutex
          @local_mutex ||= Mutex.new
        end

        def due_for_flush?
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - (@last_flush_at ||= 0) >= FLUSH_INTERVAL_SECONDS
        end

        def redis
          Rails.cache.redis
        end

        def count_key(bucket)
          "candlepin_profiling:#{bucket}:count"
        end

        def seconds_key(bucket)
          "candlepin_profiling:#{bucket}:seconds"
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
      if Katello::CandlepinProfiling.candlepin_request?(uri)
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
        if Katello::CandlepinProfiling.candlepin_request?(uri)
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

  at_exit { Katello::CandlepinProfiling.flush! }

  Rails.logger.info("[candlepin_profiling] enabled - dump with `rake katello:candlepin_profiling:report`")
end
