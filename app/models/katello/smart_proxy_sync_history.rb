require 'set'

module Katello
  class SmartProxySyncHistory < Katello::Model
    self.table_name = 'katello_smart_proxy_sync_history'

    belongs_to :smart_proxy, :class_name => "::SmartProxy", :inverse_of => :smart_proxy_sync_histories
    belongs_to :repository, :class_name => "Katello::Repository", :inverse_of => :smart_proxy_sync_histories

    scope :finished, -> { where.not(finished_at: nil) }

    def self.bulk_start(smart_proxy:, repository_ids:)
      repo_ids = Array.wrap(repository_ids).compact.uniq
      return [] if repo_ids.empty?

      result = transaction do
        where(:smart_proxy_id => smart_proxy.id, :repository_id => repo_ids).delete_all

        started_at = Time.now
        rows = repo_ids.map do |repo_id|
          {
            :smart_proxy_id => smart_proxy.id,
            :repository_id => repo_id,
            :started_at => started_at,
            :finished_at => nil,
          }
        end
        insert_all(rows, returning: %w[repository_id id])
      end
      ids_by_repo_id = result.rows.each_with_object({}) do |(repo_id, history_id), memo|
        memo[repo_id] = history_id
      end

      repo_ids.map { |repo_id| ids_by_repo_id.fetch(repo_id) }
    end

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
