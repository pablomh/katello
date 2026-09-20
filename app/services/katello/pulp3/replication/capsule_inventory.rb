module Katello
  module Pulp3
    module Replication
      # Identifies which capsule-side Pulp repository/remote/distribution objects
      # belong to which Katello repo. Classic sync names objects after repo.pulp_id;
      # replicate() instead names objects after the upstream distribution and relies
      # on a copied katello_repo_id label (and, transiently right after adopt(), only
      # a deterministic base_path) to mark ownership. Orphan cleanup needs to recognize
      # all three shapes or it will delete content replicate() just created.
      class CapsuleInventory
        def initialize(smart_proxy, katello_repos)
          @pulp_ids = Set.new(Array(katello_repos).map(&:pulp_id))
          @repo_ids = Set.new(Array(katello_repos).map { |repo| repo.id.to_s })
          @base_paths = Set.new(
            Array(katello_repos).select { |repo| Replication.replicable_type?(repo) }
                                 .map { |repo| Replication.distribution_path_for(smart_proxy, repo) }
          )
        end

        def known_object?(object)
          @repo_ids.include?(self.class.repo_id_of(object)) ||
            @pulp_ids.include?(object.try(:name)) ||
            @base_paths.include?(object.try(:base_path))
        end

        # Names recognized as managed repositories/remotes: every Katello pulp_id, plus
        # the name of any given distribution that resolves as known (replicate() keeps a
        # repo's repository/remote/distribution triad name-aligned, so a repository/remote
        # not yet directly labeled is still recognizable via its co-named distribution).
        def known_names(distributions = [])
          @pulp_ids + Array(distributions).select { |dist| known_object?(dist) }.filter_map { |dist| dist.try(:name) }
        end

        def self.known_names(smart_proxy, katello_repos, distributions = [])
          new(smart_proxy, katello_repos).known_names(distributions)
        end

        def self.matching_repositories(distributions, scope: ::Katello::Repository.all)
          names = Array(distributions).filter_map { |dist| dist.try(:name) }.uniq
          repo_ids = Array(distributions).filter_map { |dist| repo_id_of(dist) }.uniq
          return scope.none if names.empty? && repo_ids.empty?

          scope.where(pulp_id: names).or(scope.where(id: repo_ids))
        end

        def self.linked_to_repository?(distribution)
          distribution.try(:repository).present? ||
            distribution.try(:repository_version).present? ||
            distribution.try(:publication).present?
        end

        def self.repo_id_of(object)
          labels = object.try(:pulp_labels)
          return nil unless labels.is_a?(Hash)

          labels.with_indifferent_access[::Katello::Pulp3::DistributionLabels::REPO_ID]
        end
      end
    end
  end
end
