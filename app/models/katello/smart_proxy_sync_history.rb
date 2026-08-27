require 'set'

module Katello
  class SmartProxySyncHistory < Katello::Model
    self.table_name = 'katello_smart_proxy_sync_history'

    belongs_to :smart_proxy, :class_name => "::SmartProxy", :inverse_of => :smart_proxy_sync_histories
    belongs_to :repository, :class_name => "Katello::Repository", :inverse_of => :smart_proxy_sync_histories

    scope :finished, -> { where.not(finished_at: nil) }

    def self.synced_repository_ids_for(smart_proxy, repos)
      repo_ids = Array.wrap(repos).compact.filter_map do |repo|
        repo.respond_to?(:id) ? repo.id : repo
      end
      return Set.new if repo_ids.empty?

      Set.new(
        where(:smart_proxy_id => smart_proxy.id, :repository_id => repo_ids)
          .finished
          .distinct
          .pluck(:repository_id)
      )
    end
  end
end
