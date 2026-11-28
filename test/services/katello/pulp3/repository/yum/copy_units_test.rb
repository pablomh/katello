require 'katello_test_helper'

module Katello
  module Service
    class Repository
      class YumCopyUnitsTest < ::ActiveSupport::TestCase
        include Katello::Pulp3Support

        def setup
          @mock_smart_proxy = mock('smart_proxy')
          @mock_smart_proxy.stubs(:pulp3_support?).returns(true)
          @mock_smart_proxy.stubs(:pulp2_preferred_for_type?).returns(false)
          @repo = katello_repositories(:fedora_17_x86_64_duplicate)
          @repo_service = @repo.backend_service(@mock_smart_proxy)
        end

        def test_copy_all_disables_dependency_solving
          source_repo = katello_repositories(:fedora_17_x86_64)
          source_repo.stubs(:version_href).returns('/pulp/api/v3/repositories/rpm/rpm/source/versions/1/')
          @repo_service.stubs(:repository_reference).returns(
            stub(:repository_href => '/pulp/api/v3/repositories/rpm/rpm/dest/'))

          copy_api = mock('copy_api')
          Katello::Pulp3::Api::Yum.any_instance.stubs(:copy_api).returns(copy_api)
          copy_api.expects(:copy_content).once.returns('copy_task').with do |data|
            data.dependency_solving == false &&
              data.config == [{
                source_repo_version: '/pulp/api/v3/repositories/rpm/rpm/source/versions/1/',
                dest_repo: '/pulp/api/v3/repositories/rpm/rpm/dest/',
              }]
          end

          assert_equal ['copy_task'], @repo_service.copy_all(source_repo)
        end

        def test_copy_all_skips_dependency_solving_for_copy_models_without_it
          source_repo = katello_repositories(:fedora_17_x86_64)
          source_repo.stubs(:version_href).returns('/pulp/api/v3/repositories/rpm/rpm/source/versions/1/')
          @repo_service.stubs(:repository_reference).returns(
            stub(:repository_href => '/pulp/api/v3/repositories/rpm/rpm/dest/'))

          copy_api = mock('copy_api')
          Katello::Pulp3::Api::Yum.any_instance.stubs(:copy_api).returns(copy_api)
          Katello::Pulp3::Api::Yum.stubs(:copy_class).returns(PulpAnsibleClient::Copy)
          copy_api.expects(:copy_content).once.returns('copy_task')

          assert_equal ['copy_task'], @repo_service.copy_all(source_repo)
        end

        def test_copy_all_removes_existing_content_first_when_asked
          source_repo = katello_repositories(:fedora_17_x86_64)
          source_repo.stubs(:version_href).returns('/pulp/api/v3/repositories/rpm/rpm/source/versions/1/')
          @repo_service.stubs(:repository_reference).returns(
            stub(:repository_href => '/pulp/api/v3/repositories/rpm/rpm/dest/'))

          copy_api = mock('copy_api')
          repositories_api = mock('repositories_api')
          Katello::Pulp3::Api::Yum.any_instance.stubs(:copy_api).returns(copy_api)
          Katello::Pulp3::Api::Yum.any_instance.stubs(:repositories_api).returns(repositories_api)
          repositories_api.expects(:modify).once
            .with('/pulp/api/v3/repositories/rpm/rpm/dest/', remove_content_units: ['*'])
            .returns('remove_task')
          copy_api.expects(:copy_content).once.returns('copy_task')

          assert_equal %w(remove_task copy_task), @repo_service.copy_all(source_repo, remove_all: true)
        end

        def test_copy_content_chunked_limits_units_copied
          data = PulpRpmClient::Copy.new
          data.config = []

          content = []
          30_001.times { |i| content << i }

          3.times { data.config << { content: content } }

          mock_api = "test"
          Katello::Pulp3::Api::Yum.any_instance.expects(:copy_api).returns(mock_api).times(12)
          mock_api.stubs(:copy_content).returns("copied")

          @repo_service.copy_content_chunked(data)
        end

        def test_copy_content_chunked_sends_one_destination_slice_per_request
          data = PulpRpmClient::Copy.new
          data.dependency_solving = false
          data.config = [
            { source_repo_version: "repo version", dest_repo: "dest repo 1", content: (0..9_999).to_a },
            { source_repo_version: "repo version", dest_repo: "dest repo 2", content: (10_000..20_000).to_a },
          ]

          mock_api = mock('copy_api')
          Katello::Pulp3::Api::Yum.any_instance.stubs(:copy_api).returns(mock_api)
          sent_configs = []
          mock_api.expects(:copy_content).times(3).returns("task").with do |value|
            sent_configs << value.config
            value.dependency_solving == false
          end

          assert_equal %w(task task task), @repo_service.copy_content_chunked(data)
          assert_equal [
            [{ source_repo_version: "repo version", dest_repo: "dest repo 1", content: (0..9_999).to_a }],
            [{ source_repo_version: "repo version", dest_repo: "dest repo 2", content: (10_000..19_999).to_a }],
            [{ source_repo_version: "repo version", dest_repo: "dest repo 2", content: [20_000] }],
          ], sent_configs
        end

        def test_copy_content_chunked_keeps_base_version_on_first_slice_only
          data = PulpRpmClient::Copy.new
          data.dependency_solving = false
          data.config = [
            { source_repo_version: "v1", dest_repo: "dest repo 1", content: (0..10_000).to_a, dest_base_version: 3 },
            { source_repo_version: "v2", dest_repo: "dest repo 2", content: (0..10_000).to_a, dest_base_version: 5 },
          ]

          mock_api = mock('copy_api')
          Katello::Pulp3::Api::Yum.any_instance.stubs(:copy_api).returns(mock_api)
          sent_configs = []
          mock_api.expects(:copy_content).times(4).returns("task").with do |value|
            sent_configs << value.config.first
            true
          end

          @repo_service.copy_content_chunked(data)

          bases = sent_configs.map { |config| [config[:dest_repo], config[:dest_base_version]] }
          assert_equal [["dest repo 1", 3], ["dest repo 1", nil], ["dest repo 2", 5], ["dest repo 2", nil]], bases
          assert_equal (0..10_000).to_a, sent_configs[0][:content] + sent_configs[1][:content]
        end

        def test_copy_content_chunked_does_not_reset_destinations_under_the_limit
          data = PulpRpmClient::Copy.new
          data.dependency_solving = false
          data.config = [
            { source_repo_version: "v1", dest_repo: "dest repo 1", content: (0..5_999).to_a, dest_base_version: 3 },
            { source_repo_version: "v2", dest_repo: "dest repo 2", content: (0..5_999).to_a, dest_base_version: 5 },
          ]

          mock_api = mock('copy_api')
          Katello::Pulp3::Api::Yum.any_instance.stubs(:copy_api).returns(mock_api)
          sent_configs = []
          mock_api.expects(:copy_content).times(2).returns("task").with do |value|
            sent_configs << value.config
            true
          end

          @repo_service.copy_content_chunked(data)

          assert_equal [[data.config[0]], [data.config[1]]], sent_configs
        end

        def test_copy_content_chunked_sends_small_copies_unchanged
          data = PulpRpmClient::Copy.new
          data.config = [{ source_repo_version: "v1", dest_repo: "dest repo 1", content: [1, 2], dest_base_version: 3 }]

          mock_api = mock('copy_api')
          Katello::Pulp3::Api::Yum.any_instance.stubs(:copy_api).returns(mock_api)
          mock_api.expects(:copy_content).once.with(data).returns("task")

          assert_equal "task", @repo_service.copy_content_chunked(data)
        end
      end
    end
  end
end
