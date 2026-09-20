require 'katello_test_helper'
require 'support/pulp3_support'

module Katello
  module Service
    module Pulp3
      class TestRepositoryService
      end

      class RepositoryMirrorTest < ActiveSupport::TestCase
        include Katello::Pulp3Support

        def setup
          @repo_service = TestRepositoryService.new
          @repo_mirror = ::Katello::Pulp3::RepositoryMirror.new(@repo_service)
          @repo_mirror.stubs(:common_remote_options).returns({:name => 'some_repo'})
          @repo_mirror.stubs(:remote_feed_url).returns('/a/path/to/content')
        end

        def test_remote_options_with_mirror_remote_options
          @repo_service.stubs(:mirror_remote_options).returns({:mirror_remote_option1 => 'an option'})
          expected_options = {
            :name => "some_repo",
            :url => "/a/path/to/content",
            :mirror_remote_option1 => "an option",
          }
          assert_equal expected_options, @repo_mirror.remote_options
        end

        def test_remote_options_without_mirror_options
          @repo_mirror.stubs(:common_remote_options).returns({:name => 'some_repo'})
          @repo_mirror.stubs(:remote_feed_url).returns('/a/path/to/content')
          expected_options = {
            :name => "some_repo",
            :url => "/a/path/to/content",
          }
          assert_equal expected_options, @repo_mirror.remote_options
        end

        def test_create_returns_existing_repository_without_creating
          api = mock
          repos_api = mock
          existing = OpenStruct.new(name: 'some_repo')
          @repo_service.stubs(:repo).returns(OpenStruct.new(pulp_id: 'some_repo'))
          @repo_service.stubs(:api).returns(api)
          api.expects(:list_all).with(name: 'some_repo').returns([existing])
          api.stubs(:repositories_api).returns(repos_api)
          repos_api.expects(:create).never

          assert_equal existing, @repo_mirror.create
        end

        def test_create_creates_repository_when_absent
          api = mock
          repos_api = mock
          created = OpenStruct.new(name: 'some_repo')
          @repo_service.stubs(:repo).returns(OpenStruct.new(pulp_id: 'some_repo'))
          @repo_service.stubs(:api).returns(api)
          api.expects(:list_all).with(name: 'some_repo').returns([])
          api.stubs(:repositories_api).returns(repos_api)
          repos_api.expects(:create).with(name: 'some_repo').returns(created)

          assert_equal created, @repo_mirror.create
        end
      end
    end
  end
end
