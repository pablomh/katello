module Katello
  module Rhsm
    module RequestContext
      extend ActiveSupport::Concern

      def candlepin_forward_headers
        extra_headers = {}

        modified_since = request.headers[self.class::IF_MODIFIED_SINCE_HEADER]
        if modified_since.present?
          extra_headers[self.class::IF_MODIFIED_SINCE_HEADER] = modified_since
        end

        extra_headers
      end

      def use_forwarded_correlation_id
        correlation_id = request.headers[self.class::X_CORRELATION_ID_HEADER].presence || request.request_id
        ::Logging.mdc['request'] = correlation_id if correlation_id.present?
      end
    end
  end
end
