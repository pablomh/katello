require 'katello_test_helper'
require 'support/pulp3_support'

module Katello
  module Service
    class RepositoryIsOrphanDistributionTest < ActiveSupport::TestCase
      include Katello::Pulp3Support

      def setup
        @repo = FactoryBot.create(:katello_repository, :with_product)
        @smart_proxy = smart_proxies(:four)
        @inventory = ::Katello::Pulp3::Replication::CapsuleInventory.new(@smart_proxy, [@repo])
      end

      def test_unknown_distribution_is_an_orphan
        dist = PulpFileClient::FileFileDistribution.new(
          publication: 'http://some.href',
          name: 'other name')
        assert Katello::Pulp3::SmartProxyMirrorRepository.orphan_distribution?(dist, @inventory)
      end

      def test_distribution_with_publication_is_not_an_orphan
        dist = PulpFileClient::FileFileDistribution.new(
          publication: 'http://some.href',
          name: 'name')
        @repo.update pulp_id: 'name'
        refute Katello::Pulp3::SmartProxyMirrorRepository.orphan_distribution?(dist, @inventory)
      end

      def test_distribution_without_a_publication_is_an_orphan
        dist = PulpFileClient::FileFileDistribution.new(
          publication: nil)
        assert Katello::Pulp3::SmartProxyMirrorRepository.orphan_distribution?(dist, @inventory)
      end

      def test_distribution_with_repository_and_repository_version_is_not_an_orphan
        dist = PulpAnsibleClient::AnsibleAnsibleDistribution.new(
          repository: 'http://some.href',
          repository_version: 'http://some.href/version/',
          name: 'name')
        @repo.update pulp_id: 'name'
        refute Katello::Pulp3::SmartProxyMirrorRepository.orphan_distribution?(dist, @inventory)
      end

      def test_distribution_without_repository_and_repository_version_is_an_orphan
        dist = PulpAnsibleClient::AnsibleAnsibleDistribution.new(
          repository: nil,
          repository_version: nil)
        assert Katello::Pulp3::SmartProxyMirrorRepository.orphan_distribution?(dist, @inventory)
      end

      def test_replicate_managed_distribution_with_label_is_not_an_orphan
        fedora = katello_repositories(:fedora_17_x86_64)
        inventory = ::Katello::Pulp3::Replication::CapsuleInventory.new(@smart_proxy, [fedora])
        dist = PulpRpmClient::RpmRpmDistributionResponse.new(
          name: 'upstream-generated-name',
          publication: 'http://some.href',
          pulp_labels: { 'katello_repo_id' => fedora.id.to_s })

        refute Katello::Pulp3::SmartProxyMirrorRepository.orphan_distribution?(dist, inventory)
      end

      def test_replicate_managed_distribution_without_label_yet_is_not_an_orphan_when_base_path_matches
        fedora = katello_repositories(:fedora_17_x86_64)
        inventory = ::Katello::Pulp3::Replication::CapsuleInventory.new(@smart_proxy, [fedora])
        dist = PulpRpmClient::RpmRpmDistributionResponse.new(
          name: 'not-yet-relabeled',
          publication: 'http://some.href',
          base_path: ::Katello::Pulp3::Replication.distribution_path_for(@smart_proxy, fedora))

        refute Katello::Pulp3::SmartProxyMirrorRepository.orphan_distribution?(dist, inventory)
      end
    end
  end
end
