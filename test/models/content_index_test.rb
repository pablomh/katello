require 'katello_test_helper'

module Katello
  class ContentIndexTest < ActiveSupport::TestCase
    def setup
      @index = ContentIndex.create!(:version_href => '/pulp/api/v3/repositories/rpm/rpm/indexed/versions/1/')
      @repo = katello_repositories(:fedora_17_x86_64)
      @other_repo = katello_repositories(:fedora_17_x86_64_dev)
    end

    def test_for_version_returns_the_same_index
      assert_equal @index, ContentIndex.for_version(@index.version_href)
    end

    def test_for_version_creates_the_index_once
      href = '/pulp/api/v3/repositories/rpm/rpm/unindexed/versions/3/'

      assert_difference('ContentIndex.count', 1) do
        assert_equal href, ContentIndex.for_version(href).version_href
        ContentIndex.for_version(href)
      end
    end

    def test_for_version_recovers_when_the_uniqueness_validator_races
      duplicate = ContentIndex.new(:version_href => @index.version_href)
      duplicate.valid?
      ContentIndex.stubs(:find_or_create_by!).raises(ActiveRecord::RecordInvalid.new(duplicate))

      assert_equal @index, ContentIndex.for_version(@index.version_href)
    end

    def test_for_version_reraises_other_validation_failures
      invalid = ContentIndex.new
      invalid.valid?
      ContentIndex.stubs(:find_or_create_by!).raises(ActiveRecord::RecordInvalid.new(invalid))

      assert_raises(ActiveRecord::RecordInvalid) { ContentIndex.for_version('/pulp/api/v3/versions/unrelated/') }
    end

    def test_publishing_points_the_repository_at_the_index_of_its_version
      version_href = '/pulp/api/v3/repositories/rpm/rpm/publish/versions/1/'
      @repo.update_columns(:version_href => version_href, :content_index_id => nil)
      index = ::Katello::ContentIndex.create!(:version_href => version_href)

      @repo.publish_content_index_pointer

      assert_equal index.id, @repo.reload.content_index_id
    end

    def test_publishing_tolerates_an_index_collected_before_the_lock
      version_href = '/pulp/api/v3/repositories/rpm/rpm/publish-race/versions/1/'
      @repo.update_columns(:version_href => version_href, :content_index_id => nil)
      index = ::Katello::ContentIndex.create!(:version_href => version_href)
      ::Katello::ContentIndex.stubs(:find_by).returns(index)
      # Delete the row without marking the loaded object destroyed, as GC does
      # between the lookup and the lock.
      ::Katello::ContentIndex.where(:id => index.id).delete_all

      assert_nil @repo.publish_content_index_pointer
      assert_nil @repo.reload.content_index_id
    end

    def test_private_to_a_repository_until_another_repository_uses_it
      assert @index.private_to?(@repo)

      @repo.update!(:content_index_id => @index.id)
      assert @index.private_to?(@repo)

      @other_repo.update!(:content_index_id => @index.id)
      refute @index.private_to?(@repo)
    end

    def test_orphaned_ignores_null_pointers
      unused = ContentIndex.create!(:version_href => '/pulp/api/v3/repositories/rpm/rpm/orphan/versions/1/')
      @repo.update!(:content_index_id => @index.id)
      # @other_repo deliberately keeps a NULL content_index_id.

      assert_includes ContentIndex.orphaned, unused
      refute_includes ContentIndex.orphaned, @index
    end
  end
end
