module Katello
  module Rhsm
    module ProxyPassThrough
      extend ActiveSupport::Concern

      def proxy_request_path
        @request_path = drop_api_namespace(@_request.fullpath)
      end

      def proxy_request_body
        @request_body = @_request.body
      end

      def drop_api_namespace(original_request_path)
        prefix = "/rhsm"
        original_request_path.gsub(prefix, '')
      end

      def get
        response = Resources::Candlepin::Proxy.get(@request_path, candlepin_forward_headers)
        log_proxy_response(response)
        render_proxy_response(response)
      end

      def delete
        response = Resources::Candlepin::Proxy.delete(@request_path, @request_body.read, candlepin_forward_headers)
        log_proxy_response(response)
        render_proxy_response(response)
      end

      def post
        response = Resources::Candlepin::Proxy.post(@request_path, @request_body.read, candlepin_forward_headers)
        log_proxy_response(response)
        render_proxy_response(response)
      end

      def put
        response = Resources::Candlepin::Proxy.put(@request_path, @request_body.read, candlepin_forward_headers)
        log_proxy_response(response)
        render_proxy_response(response)
      end

      private

      def log_proxy_response(response)
        logger.debug do
          filter_sensitive_data(Katello::Resources::Candlepin::ResponseAdapter.body(response))
        end
      end

      def render_proxy_response(response)
        render(
          body: Katello::Resources::Candlepin::ResponseAdapter.body(response),
          status: Katello::Resources::Candlepin::ResponseAdapter.code(response),
          content_type: Katello::Resources::Candlepin::ResponseAdapter.content_type(response)
        )
      end
    end
  end
end
