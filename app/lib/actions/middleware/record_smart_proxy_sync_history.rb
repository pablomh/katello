require 'set'

module Actions
  module Middleware
    class RecordSmartProxySyncHistory < Dynflow::Middleware
      def repository_ids
        ids = if action.input[:repository_id]
                [action.input[:repository_id]]
              else
                Array(action.input[:repository_ids])
              end
        ids.compact.uniq
      end

      def save_smart_proxy_sync_history
        return if repository_ids.empty?
        return unless action.input[:smart_proxy_id] || action.input[:capsule_id]
        return if self.action.output[:smart_proxy_history_id] || self.action.output[:smart_proxy_history_ids]

        existing_repo_ids = ::Katello::Repository.where(id: repository_ids).pluck(:id).to_set
        smart_proxy_id = action.input[:smart_proxy_id] || action.input[:capsule_id]
        smart_proxy = ::SmartProxy.unscoped.find_by(id: smart_proxy_id)

        fail "Smart Proxy could not be found with id #{smart_proxy_id}" if smart_proxy.nil?

        missing_repo_id = repository_ids.find { |repo_id| !existing_repo_ids.include?(repo_id) }
        fail "Repository could not be found with id #{missing_repo_id}" if missing_repo_id

        history_ids = ::Katello::SmartProxySyncHistory.bulk_start(
          smart_proxy: smart_proxy,
          repository_ids: repository_ids
        )

        if history_ids.one? && action.input[:repository_id]
          self.action.output[:smart_proxy_history_id] = history_ids.first
        else
          self.action.output[:smart_proxy_history_ids] = history_ids
        end
      end

      def run(*args)
        begin
          save_smart_proxy_sync_history
        rescue => error
          Rails.logger.error("Error saving smart proxy history: #{error.message}")
        end
        pass(*args)
      end
    end
  end
end
