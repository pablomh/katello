require 'katello_test_helper'

module Katello
  module Service
    class RepositoryNextVersionTest < ActiveSupport::TestCase
      def test_next_version
        assert Katello::Pulp3::Repository.next_version?("/repo/a/versions/2/", "/repo/a/versions/3/")
        refute Katello::Pulp3::Repository.next_version?("/repo/a/versions/2/", "/repo/a/versions/4/")
        refute Katello::Pulp3::Repository.next_version?("/repo/a/versions/2/", "/repo/b/versions/3/")
        refute Katello::Pulp3::Repository.next_version?(nil, "/repo/a/versions/1/")
      end
    end
  end
end
