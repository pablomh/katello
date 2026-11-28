require 'katello_test_helper'

module ::Actions::Pulp3::Repository
  class SaveVersionsTest < ActiveSupport::TestCase
    # rubocop:disable Metrics/AbcSize
    include Katello::Pulp3Support

    def setup
      @primary = SmartProxy.pulp_primary
      @repo1 = katello_repositories(:generic_file_archive)
      @repo2 = katello_repositories(:pulp3_file_1)
    end

    def teardown
      ensure_creatable(@repo1, @primary)
      ensure_creatable(@repo2, @primary)
    end

    def test_save_new_version_in_map
      @repo1.update(version_href: "test_repo_1/1/")
      @repo2.update(version_href: "test_repo_2/2/")
      repos = [@repo1.id, @repo2.id]

      ::Katello::Repository.any_instance.stubs(:index_content).returns(nil)

      # Stub version PRN API calls via backend service
      mock_version1 = mock('version1')
      mock_version1.stubs(:prn).returns('prn:core.repositoryversion:uuid-1')
      mock_version2 = mock('version2')
      mock_version2.stubs(:prn).returns('prn:core.repositoryversion:uuid-2')

      mock_versions_api = mock('repository_versions_api')
      mock_versions_api.stubs(:read).with("test_repo_1/2/", {fields: 'prn'}).returns(mock_version1)
      mock_versions_api.stubs(:read).with("test_repo_2/3/", {fields: 'prn'}).returns(mock_version2)

      Katello::Pulp3::Repository.any_instance.stubs(:repository_versions_api).returns(mock_versions_api)
      Katello::Pulp3::Api::File.any_instance.stubs(:repository_versions_api).returns(mock_versions_api)

      tasks_map = [{ created_resources: ["test_repo_1/2/", "test_repo_2/3/"] }]

      task = ForemanTasks.sync_task(::Actions::Pulp3::Repository::SaveVersions, repos, tasks: tasks_map)

      @repo1.reload
      @repo2.reload

      assert_equal @repo1.version_href, "test_repo_1/2/"
      assert_equal @repo2.version_href, "test_repo_2/3/"
      assert_equal task.output[:contents_changed], true
      assert_empty task.output[:updated_repositories] - [@repo1.id, @repo2.id]
    end

    def test_save_new_version_from_lookup_with_nil_version_hrefs
      @repo1.update(version_href: nil)
      @repo2.update(version_href: nil)
      ::Katello::Pulp3::RepositoryReference.new(repository_href: "test_repo_1/", root_repository_id: @repo1.root_id, content_view_id: @repo1.content_view.id).save
      ::Katello::Pulp3::RepositoryReference.new(repository_href: "test_repo_2/", root_repository_id: @repo2.root_id, content_view_id: @repo2.content_view.id).save

      repos = [@repo1.id, @repo2.id]
      tasks_map = [{ created_resources: [] }]

      ::PulpFileClient::RepositoriesFileApi.any_instance.expects(:read).with("test_repo_1/").
        returns(::PulpFileClient::FileFileRepositoryResponse.new(latest_version_href: "test_repo_1/2/"))
      ::PulpFileClient::RepositoriesFileApi.any_instance.expects(:read).with("test_repo_2/").
        returns(::PulpFileClient::FileFileRepositoryResponse.new(latest_version_href: "test_repo_2/3/"))

      # Stub version PRN API calls via backend service
      mock_version1 = mock('version1')
      mock_version1.stubs(:prn).returns('prn:core.repositoryversion:uuid-1')
      mock_version2 = mock('version2')
      mock_version2.stubs(:prn).returns('prn:core.repositoryversion:uuid-2')

      mock_versions_api = mock('repository_versions_api')
      mock_versions_api.stubs(:read).with("test_repo_1/2/", {fields: 'prn'}).returns(mock_version1)
      mock_versions_api.stubs(:read).with("test_repo_2/3/", {fields: 'prn'}).returns(mock_version2)

      Katello::Pulp3::Repository.any_instance.stubs(:repository_versions_api).returns(mock_versions_api)
      Katello::Pulp3::Api::File.any_instance.stubs(:repository_versions_api).returns(mock_versions_api)

      ::Katello::Repository.any_instance.stubs(:index_content).returns(true)

      task = ForemanTasks.sync_task(::Actions::Pulp3::Repository::SaveVersions, repos, tasks: tasks_map)

      @repo1.reload
      @repo2.reload

      assert_equal @repo1.version_href, "test_repo_1/2/"
      assert_equal @repo2.version_href, "test_repo_2/3/"
      assert_equal task.output[:contents_changed], true
      assert_empty task.output[:updated_repositories] - [@repo1.id, @repo2.id]
    end

    def test_save_new_version_from_lookup
      @repo1.update(version_href: "test_repo_1/1/")
      @repo2.update(version_href: "test_repo_2/2/")
      ::Katello::Pulp3::RepositoryReference.new(repository_href: "test_repo_1/", root_repository_id: @repo1.root_id, content_view_id: @repo1.content_view.id).save
      ::Katello::Pulp3::RepositoryReference.new(repository_href: "test_repo_2/", root_repository_id: @repo2.root_id, content_view_id: @repo2.content_view.id).save

      repos = [@repo1.id, @repo2.id]
      tasks_map = [{ created_resources: [] }]

      ::PulpFileClient::RepositoriesFileApi.any_instance.expects(:read).with("test_repo_1/").
        returns(::PulpFileClient::FileFileRepositoryResponse.new(latest_version_href: "test_repo_1/2/"))
      ::PulpFileClient::RepositoriesFileApi.any_instance.expects(:read).with("test_repo_2/").
        returns(::PulpFileClient::FileFileRepositoryResponse.new(latest_version_href: "test_repo_2/3/"))

      # Stub version PRN API calls via backend service
      mock_version1 = mock('version1')
      mock_version1.stubs(:prn).returns('prn:core.repositoryversion:uuid-1')
      mock_version2 = mock('version2')
      mock_version2.stubs(:prn).returns('prn:core.repositoryversion:uuid-2')

      mock_versions_api = mock('repository_versions_api')
      mock_versions_api.stubs(:read).with("test_repo_1/2/", {fields: 'prn'}).returns(mock_version1)
      mock_versions_api.stubs(:read).with("test_repo_2/3/", {fields: 'prn'}).returns(mock_version2)

      Katello::Pulp3::Repository.any_instance.stubs(:repository_versions_api).returns(mock_versions_api)
      Katello::Pulp3::Api::File.any_instance.stubs(:repository_versions_api).returns(mock_versions_api)

      ::Katello::Repository.any_instance.stubs(:index_content).returns(true)

      task = ForemanTasks.sync_task(::Actions::Pulp3::Repository::SaveVersions, repos, tasks: tasks_map)

      @repo1.reload
      @repo2.reload

      assert_equal @repo1.version_href, "test_repo_1/2/"
      assert_equal @repo2.version_href, "test_repo_2/3/"
      assert_equal task.output[:contents_changed], true
      assert_empty task.output[:updated_repositories] - [@repo1.id, @repo2.id]
    end

    def test_save_version_with_outdated_publication
      @repo1.update(version_href: "test_repo_1/1/", publication_href: "test_publ_1/")
      ::Katello::Pulp3::RepositoryReference.new(repository_href: "test_repo_1/", root_repository_id: @repo1.root_id, content_view_id: @repo1.content_view.id).save

      tasks_map = [{ created_resources: [] }]

      ::PulpFileClient::PublicationsFileApi.any_instance.expects(:read).with("test_publ_1/").
        returns(::PulpFileClient::FileFilePublicationResponse.new(repository_version: "test_repo_1/0/"))
      ::Katello::Repository.any_instance.stubs(:index_content).returns(true)

      task = ForemanTasks.sync_task(::Actions::Pulp3::Repository::SaveVersion, @repo1, tasks: tasks_map)

      @repo1.reload

      assert_equal "test_repo_1/1/", @repo1.version_href
      assert task.output[:contents_changed]
      assert_nil task.output[:updated_repositories]
    end
    # rubocop:enable Metrics/AbcSize
  end

  class SaveVersionsAdditiveCopyTest < ActiveSupport::TestCase
    CV_REPO = "/pulp/api/v3/repositories/file/file/cv/".freeze
    LIBRARY_VERSION = "/pulp/api/v3/repositories/file/file/library/versions/7/".freeze

    def setup
      @repo1 = katello_repositories(:generic_file_archive)
    end

    def stub_version_prn(href)
      version = mock('version')
      version.stubs(:prn).returns("prn:core.repositoryversion:#{href}")
      versions_api = mock('repository_versions_api')
      versions_api.stubs(:read).with(href, {fields: 'prn'}).returns(version)
      Katello::Pulp3::Api::File.any_instance.stubs(:repository_versions_api).returns(versions_api)
    end

    def save_reference(repo, href)
      ::Katello::Pulp3::RepositoryReference.new(repository_href: href, root_repository_id: repo.root_id,
                                                content_view_id: repo.content_view.id).save
    end

    def test_additive_copy_indexes_changes_from_saved_version
      @repo1.update(version_href: "library_repo/7/")
      save_reference(@repo1, "test_repo_1/")
      stub_version_prn("test_repo_1/3/")
      @repo1.class.any_instance.expects(:index_content).with(changed_from: "library_repo/7/")

      task = ForemanTasks.sync_task(::Actions::Pulp3::Repository::SaveVersions, [@repo1.id],
                                    tasks: [{ created_resources: ["test_repo_1/3/", "other_repo/2/"] }], additive_copy: true)

      assert_equal "test_repo_1/3/", @repo1.reload.version_href
      assert task.output[:contents_changed]
      assert_equal({ @repo1.id.to_s => true }, task.output[:changed_repositories])
    end

    def test_additive_copy_without_new_version_leaves_repository_unchanged
      @repo1.update(version_href: "library_repo/7/")
      save_reference(@repo1, "test_repo_1/")
      ::PulpFileClient::RepositoriesFileApi.any_instance.expects(:read).never
      @repo1.class.any_instance.expects(:index_content).never

      task = ForemanTasks.sync_task(::Actions::Pulp3::Repository::SaveVersions, [@repo1.id],
                                    tasks: [{ created_resources: ["other_repo/2/"] }], additive_copy: true)

      assert_equal "library_repo/7/", @repo1.reload.version_href
      refute task.output[:contents_changed]
      assert_equal({ @repo1.id.to_s => false }, task.output[:changed_repositories])
    end

    def test_additive_copy_with_several_versions_indexes_from_saved_version
      @repo1.update(version_href: "test_repo_1/1/")
      save_reference(@repo1, "test_repo_1/")
      stub_version_prn("test_repo_1/3/")
      @repo1.class.any_instance.expects(:index_content).with(changed_from: "test_repo_1/1/")

      ForemanTasks.sync_task(::Actions::Pulp3::Repository::SaveVersions, [@repo1.id],
                             tasks: [{ created_resources: ["test_repo_1/2/"] }, { created_resources: ["test_repo_1/3/"] }],
                             additive_copy: true)

      assert_equal "test_repo_1/3/", @repo1.reload.version_href
    end

    def test_additive_copy_restores_version_when_indexing_fails
      @repo1.update(version_href: "test_repo_1/1/", version_prn: "prn:old")
      save_reference(@repo1, "test_repo_1/")
      stub_version_prn("test_repo_1/2/")
      @repo1.class.any_instance.expects(:index_content).raises(StandardError, "boom")

      assert_raises(ForemanTasks::TaskError) do
        ForemanTasks.sync_task(::Actions::Pulp3::Repository::SaveVersions, [@repo1.id],
                               tasks: [{ created_resources: ["test_repo_1/2/"] }], additive_copy: true)
      end

      @repo1.reload
      assert_equal "test_repo_1/1/", @repo1.version_href
      assert_equal "prn:old", @repo1.version_prn
    end

    def test_additive_copy_indexes_from_the_seed_it_directly_follows
      @repo1.update(version_href: LIBRARY_VERSION)
      save_reference(@repo1, CV_REPO)
      stub_version_prn("#{CV_REPO}versions/4/")
      @repo1.class.any_instance.expects(:index_content).with(changed_from: "#{CV_REPO}versions/3/")

      ForemanTasks.sync_task(::Actions::Pulp3::Repository::SaveVersions, [@repo1.id],
                             tasks: [{ created_resources: ["#{CV_REPO}versions/4/"] }], additive_copy: true,
                             seed_tasks: { @repo1.id.to_s => [{ created_resources: ["#{CV_REPO}versions/3/"] }] })
    end

    def test_additive_copy_ignores_a_seed_it_does_not_directly_follow
      @repo1.update(version_href: LIBRARY_VERSION)
      save_reference(@repo1, CV_REPO)
      stub_version_prn("#{CV_REPO}versions/5/")
      @repo1.class.any_instance.expects(:index_content).with(changed_from: LIBRARY_VERSION)

      ForemanTasks.sync_task(::Actions::Pulp3::Repository::SaveVersions, [@repo1.id],
                             tasks: [{ created_resources: ["#{CV_REPO}versions/5/"] }], additive_copy: true,
                             seed_tasks: { @repo1.id.to_s => [{ created_resources: ["#{CV_REPO}versions/3/"] }] })
    end
  end
end
