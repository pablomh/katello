module Katello
  module Resources
    module Candlepin
      class Proxy
        def self.logger
          ::Foreman::Logging.logger('katello/cp_proxy')
        end

        def self.post(path, body, extra_headers = {})
          logger.debug "Sending POST request to Candlepin: #{path}"
          CandlepinResource.issue_request(
            method: :post,
            path: path_with_cp_prefix(path),
            payload: body,
            headers: request_headers(extra_headers)
          )
        end

        def self.delete(path, body = nil, extra_headers = {})
          logger.debug "Sending DELETE request to Candlepin: #{path}"
          CandlepinResource.issue_request(
            method: :delete,
            path: path_with_cp_prefix(path),
            payload: body,
            headers: request_headers(extra_headers)
          )
        end

        def self.get(path, extra_headers = {})
          logger.debug "Sending GET request to Candlepin: #{path}"
          CandlepinResource.issue_request(
            method: :get,
            path: path_with_cp_prefix(path),
            headers: request_headers(extra_headers)
          )
        rescue RestClient::NotModified => e
          e.response
        end

        def self.put(path, body, extra_headers = {})
          logger.debug "Sending PUT request to Candlepin: #{path}"
          CandlepinResource.issue_request(
            method: :put,
            path: path_with_cp_prefix(path),
            payload: body,
            headers: request_headers(extra_headers)
          )
        end

        def self.path_with_cp_prefix(path)
          CandlepinResource.prefix + path
        end

        def self.request_headers(extra_headers = {})
          CandlepinResource.default_headers.merge(extra_headers || {})
        end
      end
    end
  end
end
