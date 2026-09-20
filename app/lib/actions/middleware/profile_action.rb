# Opt-in instrumentation for comparing capsule sync approaches (classic vs. replicate()).
# Only registered when KATELLO_PROFILE_CAPSULE_SYNC is set at boot - see
# lib/katello/engine.rb and lib/katello/tasks/profile_capsule_sync.rake.
#
# Wraps every action's `run` (not just the classic-vs-replicate ones - this is a
# world-level middleware, like RecordErrataApplication) so per-poll-tick invocations
# of AbstractAsyncTask subclasses are each captured and merged, not just the first.
module Actions
  module Middleware
    class ProfileAction < Dynflow::Middleware
      def run(*args)
        return pass(*args) unless ENV['KATELLO_PROFILE_CAPSULE_SYNC']

        ::Katello::Pulp3::Api::CoreProfiling.reset_current_counter
        sql_count = 0
        sql_time = 0.0
        capturing_thread = Thread.current
        callback = lambda do |_name, start, finish, _id, _payload|
          next unless Thread.current == capturing_thread
          sql_count += 1
          sql_time += (finish - start)
        end

        result = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { pass(*args) }

        api_counter = ::Katello::Pulp3::Api::CoreProfiling.current_counter
        merge_profiling_output(sql_count, sql_time, api_counter[:count], api_counter[:time])
        result
      end

      private

      # Merge-add, not overwrite: polling actions invoke `run` multiple times over
      # their lifetime (once per suspend/resume tick) and each tick's counts must
      # accumulate onto the same action's output, not replace the previous tick's.
      def merge_profiling_output(sql_count, sql_time, api_call_count, api_time)
        # Bracket-assign a single key onto the existing output hash - action.output = {}
        # would replace the whole hash and wipe out pulp_tasks/task_groups/etc.
        existing = action.output[:profiling] || {sql_count: 0, sql_time: 0.0, api_call_count: 0, api_time: 0.0}
        action.output[:profiling] = {
          sql_count: existing[:sql_count] + sql_count,
          sql_time: existing[:sql_time] + sql_time,
          api_call_count: existing[:api_call_count] + api_call_count,
          api_time: existing[:api_time] + api_time,
        }
      end
    end
  end
end
