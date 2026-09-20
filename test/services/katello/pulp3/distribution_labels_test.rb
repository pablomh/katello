require 'katello_test_helper'

module Katello::Pulp3
  class DistributionLabelsTest < ActiveSupport::TestCase
    it 'labels a distribution with the repository id' do
      repo = katello_repositories(:fedora_17_x86_64)

      assert_equal({ 'katello_repo_id' => repo.id.to_s }, ::Katello::Pulp3::DistributionLabels.for(repo))
    end

    it 'uses the constant repo id key' do
      assert_equal 'katello_repo_id', ::Katello::Pulp3::DistributionLabels::REPO_ID
    end
  end
end
