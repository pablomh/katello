module Katello
  module Pulp3
    class DistributionLabels
      REPO_ID = 'katello_repo_id'.freeze

      def self.for(repo)
        { REPO_ID => repo.id.to_s }
      end
    end
  end
end
