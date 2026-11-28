module Katello
  module Pulp3
    # The range-filter capability belongs to the rpm content family, not to each type.
    module YumContentUnit
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def supports_version_range_filters?
          Katello::Pulp3::Api::Yum.version_range_filters?
        end
      end
    end
  end
end
