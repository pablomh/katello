namespace :katello do
  desc "Profile a capsule sync's DB/Pulp-API load for before/after comparison. " \
       "Requires KATELLO_PROFILE_CAPSULE_SYNC=1 set (and the Dynflow executor restarted) " \
       "before running. SMART_PROXY_ID=1"
  task :profile_capsule_sync => ['environment'] do
    unless ENV['KATELLO_PROFILE_CAPSULE_SYNC']
      puts "WARNING: KATELLO_PROFILE_CAPSULE_SYNC is not set - profiling data will be empty. " \
           "Set it in the environment of whatever process runs the Dynflow executor and restart " \
           "that service before running this task."
    end

    smart_proxy = ::SmartProxy.unscoped.find(ENV['SMART_PROXY_ID'])

    wall_clock_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    task_result = ForemanTasks.sync_task(::Actions::Katello::CapsuleContent::Sync, smart_proxy)
    wall_clock = Process.clock_gettime(Process::CLOCK_MONOTONIC) - wall_clock_start

    execution_plan = task_result.execution_plan
    run_step_by_action_id = execution_plan.run_steps.index_by(&:action_id)

    totals = {sql_count: 0, sql_time: 0.0, api_call_count: 0, api_time: 0.0, wall_time: 0.0}
    by_class = Hash.new { |hash, key| hash[key] = {sql_count: 0, sql_time: 0.0, api_call_count: 0, api_time: 0.0, wall_time: 0.0, count: 0} }

    execution_plan.actions.each do |action|
      profiling = (action.output || {})[:profiling] || {}
      run_step = run_step_by_action_id[action.id]
      row = by_class[action.class.name]
      row[:count] += 1
      row[:sql_count] += profiling[:sql_count] || 0
      row[:sql_time] += profiling[:sql_time] || 0.0
      row[:api_call_count] += profiling[:api_call_count] || 0
      row[:api_time] += profiling[:api_time] || 0.0
      row[:wall_time] += run_step&.real_time || 0.0

      totals[:sql_count] += profiling[:sql_count] || 0
      totals[:sql_time] += profiling[:sql_time] || 0.0
      totals[:api_call_count] += profiling[:api_call_count] || 0
      totals[:api_time] += profiling[:api_time] || 0.0
    end

    puts "Capsule sync profiling report for smart proxy #{smart_proxy.name} (##{smart_proxy.id})"
    puts "=" * 78
    puts "Overall wall clock:     %.3fs" % wall_clock
    puts "Total SQL queries:      #{totals[:sql_count]} (%.3fs)" % totals[:sql_time]
    puts "Total Pulp API calls:   #{totals[:api_call_count]} (%.3fs)" % totals[:api_time]
    puts
    puts "Per action class:"
    puts "%-55s %6s %10s %10s %10s %10s" % ["action", "count", "sql_n", "sql_s", "api_n", "api_s"]
    by_class.sort_by { |_klass, row| -row[:wall_time] }.each do |klass, row|
      puts "%-55s %6d %10d %10.3f %10d %10.3f" % [klass, row[:count], row[:sql_count], row[:sql_time], row[:api_call_count], row[:api_time]]
    end
  end
end
