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

        def test_create_skips_when_repository_already_exists
          existing = stub(:pulp_href => '/pulp/api/v3/repositories/rpm/rpm/1/')
          api = mock
          @repo_mirror.stubs(:api).returns(api)
          @repo_mirror.stubs(:backend_object_name).returns('some_repo')
          api.expects(:list_all).with(:name => 'some_repo').returns([existing])
          api.expects(:repositories_api).never

          assert_equal existing, @repo_mirror.create
        end

        def test_create_when_repository_is_missing
          created = stub(:pulp_href => '/pulp/api/v3/repositories/rpm/rpm/2/')
          api = mock
          repos_api = mock
          @repo_mirror.stubs(:api).returns(api)
          @repo_mirror.stubs(:backend_object_name).returns('some_repo')
          api.expects(:list_all).with(:name => 'some_repo').returns([])
          api.expects(:repositories_api).returns(repos_api)
          repos_api.expects(:create).with(:name => 'some_repo').returns(created)

          assert_equal created, @repo_mirror.create
        end
      end
    end
  end
end
