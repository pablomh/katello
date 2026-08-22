module Katello
  module Pulp3
    class DistributionLabels
      ORG = 'katello_org'.freeze
      LE = 'katello_le'.freeze
      CV = 'katello_cv'.freeze
      REPO_ID = 'katello_repo_id'.freeze
      CONTENT_TYPE = 'katello_content_type'.freeze

      def self.for(repo)
        labels = {
          REPO_ID => repo.id.to_s,
          CONTENT_TYPE => repo.content_type.to_s,
        }
        labels[ORG] = repo.organization.label if repo.organization
        labels[LE] = repo.environment.label if repo.environment
        labels[CV] = repo.content_view.label if repo.content_view
        labels
      end

      def self.q_select(environment: nil, content_view: nil, repository: nil, lifecycle_environments: nil)
        clauses = []
        if repository
          clauses << label_clause(REPO_ID, repository.id)
        else
          environments = Array(environment || lifecycle_environments).compact
          if environments.any?
            le_clauses = environments.map { |env| label_clause(LE, env.label) }
            clauses << ((le_clauses.size == 1) ? le_clauses.first : "(#{le_clauses.join(' OR ')})")
          end
          clauses << label_clause(CV, content_view.label) if content_view
        end
        clauses.presence&.join(' AND ')
      end

      def self.label_clause(key, value)
        escaped = value.to_s.gsub('\\', '\\\\').gsub("'", "\\\\'")
        "pulp_label_select='#{key}=#{escaped}'"
      end
      private_class_method :label_clause
    end
  end
end
