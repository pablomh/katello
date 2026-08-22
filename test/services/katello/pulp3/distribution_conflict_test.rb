require 'katello_test_helper'

module Katello
  module Pulp3
    class DistributionConflictTest < ActiveSupport::TestCase
      def test_create_race_unique
        assert DistributionConflict.create_race?('{"base_path": ["This field must be unique."]}')
        assert DistributionConflict.create_race?(OpenStruct.new(message: "base_path: code='unique'"))
      end

      def test_create_race_overlap
        assert DistributionConflict.create_race?("Overlaps with existing distribution.")
        assert DistributionConflict.create_race?(%(base_path: ["Overlaps with existing distribution."]))
      end

      def test_unrelated_error_is_not_a_create_race
        refute DistributionConflict.create_race?('Connection refused')
        refute DistributionConflict.create_race?('publication is missing')
      end
    end
  end
end
