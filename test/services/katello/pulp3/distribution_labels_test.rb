require 'katello_test_helper'

module Katello
  module Pulp3
    class DistributionLabelsTest < ActiveSupport::TestCase
      def setup
        @repo = katello_repositories(:fedora_17_x86_64)
      end

      def test_for_repo_includes_org_le_cv_and_type
        labels = DistributionLabels.for(@repo)
        assert_equal @repo.id.to_s, labels[DistributionLabels::REPO_ID]
        assert_equal 'yum', labels[DistributionLabels::CONTENT_TYPE]
        assert_equal @repo.organization.label, labels[DistributionLabels::ORG]
        assert_equal @repo.environment.label, labels[DistributionLabels::LE]
        assert_equal @repo.content_view.label, labels[DistributionLabels::CV]
        refute labels.key?('katello_cvv')
      end

      def test_q_select_full_sync_is_nil_without_scope
        assert_nil DistributionLabels.q_select
      end

      def test_q_select_repository
        q = DistributionLabels.q_select(repository: @repo)
        assert_equal "pulp_label_select='katello_repo_id=#{@repo.id}'", q
      end

      def test_q_select_environment_and_content_view
        q = DistributionLabels.q_select(environment: @repo.environment, content_view: @repo.content_view)
        assert_includes q, "pulp_label_select='katello_le=#{@repo.environment.label}'"
        assert_includes q, "pulp_label_select='katello_cv=#{@repo.content_view.label}'"
        assert_includes q, ' AND '
      end

      def test_q_select_multiple_lifecycle_environments
        library = katello_environments(:library)
        dev = katello_environments(:dev)
        q = DistributionLabels.q_select(lifecycle_environments: [library, dev])
        assert_includes q, library.label
        assert_includes q, dev.label
        assert_includes q, ' OR '
      end
    end
  end
end
