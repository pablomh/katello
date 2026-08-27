require 'katello_test_helper'

module Katello::Pulp3
  class DistributionConflictTest < ActiveSupport::TestCase
    it 'matches both async task and direct api race messages' do
      async_error = ::Katello::Errors::Pulp3Error.new(
        "{'base_path': [ErrorDetail(string='This field must be unique.', code='unique')]}"
      )
      api_error = RuntimeError.new('{"base_path":["Overlaps with existing distribution"]}')

      assert ::Katello::Pulp3::DistributionConflict.create_race?(async_error)
      assert ::Katello::Pulp3::DistributionConflict.create_race?(api_error)
      refute ::Katello::Pulp3::DistributionConflict.create_race?("Remote artifacts cannot be exported")
    end

    it 'matches an overlap message with no base_path field name at all' do
      # The real overlap error is not always nested under a "base_path" key.
      assert ::Katello::Pulp3::DistributionConflict.create_race?("Overlaps with existing distribution.")
      assert ::Katello::Pulp3::DistributionConflict.create_race?("base_path: [\"Overlaps with existing distribution.\"]")
    end
  end
end
