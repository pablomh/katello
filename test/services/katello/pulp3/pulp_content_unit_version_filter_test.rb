require 'katello_test_helper'

module Katello
  module Service
    module Pulp3
      class PulpContentUnitVersionFilterTest < ActiveSupport::TestCase
        def setup
          @repo = katello_repositories(:fedora_17_x86_64)
          @repo.version_href = "/pulp/api/v3/repositories/rpm/rpm/cv/versions/3/"
        end

        def test_version_filter_replaces_the_repository_version
          range = ["/pulp/api/v3/repositories/rpm/rpm/library/versions/7/", @repo.version_href]
          Katello::Pulp3::Rpm.expects(:content_unit_list).once.returns('count' => 0, 'results' => []).with do |opts|
            opts['added_between'] == range && !opts.key?('repository_version') && opts['arch__ne'] == 'src'
          end

          Katello::Pulp3::Rpm.pulp_units_batch_for_repo(@repo, version_filter: { added_between: range }).to_a
        end

        def test_repository_version_is_the_default_filter
          Katello::Pulp3::Rpm.expects(:content_unit_list).once.returns('count' => 0, 'results' => []).with do |opts|
            opts['repository_version'] == @repo.version_href && !opts.key?('added_between')
          end

          Katello::Pulp3::Rpm.pulp_units_batch_for_repo(@repo).to_a
        end

        def test_only_pulp_rpm_types_accept_version_ranges
          assert Katello::Pulp3::Rpm.supports_version_range_filters?
          assert Katello::Pulp3::Erratum.supports_version_range_filters?
          refute Katello::Pulp3::Deb.supports_version_range_filters?
          refute Katello::Pulp3::FileUnit.supports_version_range_filters?
        end

        def test_pulp_rpm_client_without_range_filter_serialization_falls_back
          stub_constant(PulpRpmClient, :VERSION, '3.39.0') do
            refute Katello::Pulp3::Rpm.supports_version_range_filters?
            @repo.version_href = "/pulp/api/v3/repositories/rpm/rpm/cv/versions/3/"
            assert_nil @repo.version_change_filters("/pulp/api/v3/repositories/rpm/rpm/library/versions/7/")
          end
          stub_constant(PulpRpmClient, :VERSION, '3.39.1') do
            assert Katello::Pulp3::Rpm.supports_version_range_filters?
          end
        end

        def test_deb_never_asks_for_a_version_range
          deb_repo = katello_repositories(:debian_10_amd64)
          deb_repo.version_href = "/pulp/api/v3/repositories/deb/apt/cv/versions/3/"

          assert_nil deb_repo.version_change_filters("/pulp/api/v3/repositories/deb/apt/library/versions/2/")
          assert_equal({ added: { repository_version_added: deb_repo.version_href },
                         removed: { repository_version_removed: deb_repo.version_href } },
                       deb_repo.version_change_filters("/pulp/api/v3/repositories/deb/apt/cv/versions/2/"))
        end
      end
    end
  end
end
