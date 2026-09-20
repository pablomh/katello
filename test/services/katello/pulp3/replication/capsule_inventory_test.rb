require 'katello_test_helper'

module Katello::Pulp3::Replication
  class CapsuleInventoryTest < ActiveSupport::TestCase
    let(:smart_proxy) { smart_proxies(:four) }
    let(:fedora) { katello_repositories(:fedora_17_x86_64) } # yum, replicable
    let(:file_repo) { katello_repositories(:pulp3_file_1) } # file, not replicable

    it 'recognizes an object known by its katello_repo_id label, regardless of name' do
      inventory = CapsuleInventory.new(smart_proxy, [fedora])
      dist = OpenStruct.new(name: 'upstream-generated-name', pulp_labels: { 'katello_repo_id' => fedora.id.to_s })

      assert inventory.known_object?(dist)
    end

    it 'recognizes an object known by matching repo.pulp_id (classic sync)' do
      inventory = CapsuleInventory.new(smart_proxy, [fedora])
      dist = OpenStruct.new(name: fedora.pulp_id, pulp_labels: nil)

      assert inventory.known_object?(dist)
    end

    it 'recognizes a replicable-type object known only by base_path, with no label yet' do
      inventory = CapsuleInventory.new(smart_proxy, [fedora])
      dist = OpenStruct.new(
        name: 'not-yet-relabeled',
        pulp_labels: nil,
        base_path: ::Katello::Pulp3::Replication.distribution_path_for(smart_proxy, fedora)
      )

      assert inventory.known_object?(dist)
    end

    it 'does not recognize a coincidental base_path match for a non-replicable content type' do
      inventory = CapsuleInventory.new(smart_proxy, [file_repo])
      dist = OpenStruct.new(
        name: 'unrelated',
        pulp_labels: nil,
        base_path: ::Katello::Pulp3::Replication.distribution_path_for(smart_proxy, file_repo)
      )

      refute inventory.known_object?(dist)
    end

    it 'does not recognize a fully unrelated object' do
      inventory = CapsuleInventory.new(smart_proxy, [fedora])
      dist = OpenStruct.new(name: 'nope', pulp_labels: nil, base_path: 'nope/path')

      refute inventory.known_object?(dist)
    end

    it 'known_names includes repo pulp_ids plus names of distributions resolved as known' do
      known_dist = OpenStruct.new(name: 'replicated-repo-remote-name', pulp_labels: { 'katello_repo_id' => fedora.id.to_s })
      unknown_dist = OpenStruct.new(name: 'someone-elses-repo', pulp_labels: nil, base_path: 'other/path')

      names = CapsuleInventory.known_names(smart_proxy, [fedora], [known_dist, unknown_dist])

      assert_includes names, fedora.pulp_id
      assert_includes names, known_dist.name
      refute_includes names, unknown_dist.name
    end

    it 'matching_repositories resolves via label or pulp_id' do
      by_label = OpenStruct.new(name: 'renamed', pulp_labels: { 'katello_repo_id' => fedora.id.to_s })
      by_name = OpenStruct.new(name: file_repo.pulp_id, pulp_labels: nil)

      found = CapsuleInventory.matching_repositories([by_label, by_name])

      assert_includes found, fedora
      assert_includes found, file_repo
    end

    it 'matching_repositories returns none for an empty distribution list' do
      assert_empty CapsuleInventory.matching_repositories([])
    end

    it 'linked_to_repository? is true when only publication is present' do
      dist = OpenStruct.new(publication: 'http://some.href', repository: nil, repository_version: nil)

      assert CapsuleInventory.linked_to_repository?(dist)
    end

    it 'linked_to_repository? is false when repository, repository_version, and publication are all absent' do
      dist = OpenStruct.new(publication: nil, repository: nil, repository_version: nil)

      refute CapsuleInventory.linked_to_repository?(dist)
    end
  end
end
