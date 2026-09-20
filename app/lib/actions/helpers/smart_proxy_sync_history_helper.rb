module Actions
  module Helpers
    module SmartProxySyncHistoryHelper
      def self.included(base)
        base.middleware.use ::Actions::Middleware::RecordSmartProxySyncHistory
      end

      def smart_proxy_history_ids
        Array(output[:smart_proxy_history_id]) + Array(output[:smart_proxy_history_ids])
      end

      def done?
        is_done = super
        if is_done && smart_proxy_history_ids.any?
          ::Katello::SmartProxySyncHistory.where(:id => smart_proxy_history_ids, :finished_at => nil).update_all(finished_at: Time.now)
        end
        is_done
      end

      def rescue_external_task(error)
        if smart_proxy_history_ids.any?
          ::Katello::SmartProxySyncHistory.where(:id => smart_proxy_history_ids, :finished_at => nil).delete_all
        end
        super
      end
    end
  end
end
