module Actions
  module Middleware
    class ResetUpstreamCandlepinConnection < Dynflow::Middleware
      def run(*args)
        reset_connection { pass(*args) }
      end

      def finalize(*args)
        reset_connection { pass(*args) }
      end

      private

      def reset_connection
        yield
      ensure
        ::Katello::Resources::Candlepin::UpstreamCandlepinResource.reset_connection!
      end
    end
  end
end
