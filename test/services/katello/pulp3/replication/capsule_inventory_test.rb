require 'katello_test_helper'
require 'set'

module Katello
  module Pulp3
    module Replication
      class CapsuleInventoryTest < ActiveSupport::TestCase
        def setup
          @repo = katello_repositories(:fedora_17_x86_64)
        end

        def test_known_by_pulp_id_name
          distro = OpenStruct.new(name: @repo.pulp_id, base_path: 'unrelated')
          assert CapsuleInventory.known_distribution?(distro, [@repo])
        end

        def test_known_by_base_path
          distro = OpenStruct.new(name: 'upstream-distro-name', base_path: @repo.relative_path)
          assert CapsuleInventory.known_distribution?(distro, [@repo])
        end

        def test_unknown_distribution
          distro = OpenStruct.new(name: 'other', base_path: 'somewhere-else')
          refute CapsuleInventory.known_distribution?(distro, [@repo])
        end

        def test_known_names_include_matching_distro_name
          distro = OpenStruct.new(name: 'copied-from-satellite', base_path: @repo.relative_path)
          names = CapsuleInventory.known_names([@repo], [distro])
          assert_kind_of Set, names
          assert_includes names, @repo.pulp_id
          assert_includes names, 'copied-from-satellite'
        end

        def test_matching_repositories_by_pulp_id
          distro = OpenStruct.new(name: @repo.pulp_id, base_path: 'unrelated')
          found = CapsuleInventory.matching_repositories([distro])
          assert_includes found.map(&:id), @repo.id
        end

        def test_matching_repositories_by_relative_path
          distro = OpenStruct.new(name: 'upstream-distro-name', base_path: @repo.relative_path)
          found = CapsuleInventory.matching_repositories([distro])
          assert_includes found.map(&:id), @repo.id
        end

        def test_matching_repositories_by_container_name
          docker = katello_repositories(:busybox)
          distro = OpenStruct.new(name: 'upstream', base_path: docker.container_repository_name)
          found = CapsuleInventory.matching_repositories([distro])
          assert_includes found.map(&:id), docker.id
        end
      end
    end
  end
end
