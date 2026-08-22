require 'set'

module Katello
  module Pulp3
    module Replication
      # Capsule Pulp objects created by replicate() are named after the upstream
      # distribution, not repo.pulp_id. Match inventory by base_path, and still
      # accept legacy pulp_id names so unlabeled leftovers are not orphaned.
      class CapsuleInventory
        attr_reader :paths

        def initialize(katello_repos)
          @repos = Array(katello_repos)
          @names = Set.new(@repos.map(&:pulp_id).compact)
          @paths = Set.new(@repos.map { |repo| Replication.distribution_path_for(repo) }.compact)
        end

        def known_distribution?(distribution)
          @names.include?(self.class.name_of(distribution)) ||
            @paths.include?(self.class.base_path_of(distribution))
        end

        def known_names(distros = [])
          names = @names.dup
          Array(distros).each do |distro|
            names << self.class.name_of(distro) if @paths.include?(self.class.base_path_of(distro))
          end
          names
        end

        def self.known_names(katello_repos, distros = [])
          new(katello_repos).known_names(distros)
        end

        def self.known_paths(katello_repos)
          new(katello_repos).paths.to_a
        end

        def self.known_distribution?(distribution, katello_repos)
          new(katello_repos).known_distribution?(distribution)
        end

        def self.matching_repositories(distributions, scope: ::Katello::Repository.where.not(:environment_id => nil))
          names = Array(distributions).map { |distro| name_of(distro) }.compact.uniq
          paths = Array(distributions).map { |distro| base_path_of(distro) }.reject(&:blank?).uniq
          found = []
          found.concat(scope.where(:pulp_id => names).to_a) if names.any?
          if paths.any?
            path_values = (paths + paths.map { |path| "/#{path}" }).uniq
            found.concat(scope.where(:relative_path => path_values).to_a)
            found.concat(scope.where(:container_repository_name => paths).to_a)
          end
          found.uniq
        end

        def self.name_of(object)
          field(object, :name)
        end

        def self.base_path_of(object)
          field(object, :base_path).to_s.sub(%r{^/}, '')
        end

        # A distribution can outlive its repository (partial replicate() run).
        def self.linked_to_repository?(object)
          field(object, :repository).present? || field(object, :repository_version).present?
        end

        def self.field(object, key)
          object.try(key) || object[key] || object[key.to_s]
        end
      end
    end
  end
end
