namespace :katello do
  namespace :candlepin_profiling do
    desc "Dump aggregated Candlepin HTTP and DB counters collected since boot or last reset"
    task :report => :environment do
      unless defined?(Katello::CandlepinProfiling)
        puts "Candlepin profiling is not enabled. Set KATELLO_CANDLEPIN_PROFILING=1 and restart the server."
        next
      end

      rows = Katello::CandlepinProfiling.report
      if rows.empty?
        puts "No data recorded yet."
        next
      end

      printf("%-35s %10s %12s %10s\n", "bucket", "count", "total_ms", "avg_ms")
      rows.each do |row|
        printf("%-35s %10d %12.2f %10.2f\n", row[:bucket], row[:count], row[:total_ms], row[:avg_ms])
      end
    end

    desc "Reset Candlepin profiling counters"
    task :reset => :environment do
      unless defined?(Katello::CandlepinProfiling)
        puts "Candlepin profiling is not enabled. Set KATELLO_CANDLEPIN_PROFILING=1 and restart the server."
        next
      end

      Katello::CandlepinProfiling.reset!
      puts "Candlepin profiling counters reset."
    end
  end
end
