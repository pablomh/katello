module Katello
  module Resources
    module Candlepin
      class Proxy
        def self.logger
          ::Foreman::Logging.logger('katello/cp_proxy')
        end

        def self.post(path, body)
          logger.debug "Sending POST request to Candlepin: #{path}"
          conn = CandlepinResource.faraday_connection(path_with_cp_prefix(path))
          conn.post(path_with_cp_prefix(path)) do |req|
            req.headers.merge!({:accept => :json, :content_type => :json}.merge(User.cp_oauth_header))
            req.body = body
          end
        end

        def self.delete(path, body = nil)
          logger.debug "Sending DELETE request to Candlepin: #{path}"
          conn = CandlepinResource.faraday_connection(path_with_cp_prefix(path))
          conn.delete(path_with_cp_prefix(path)) do |req|
            req.headers.merge!({:accept => :json, :content_type => :json}.merge(User.cp_oauth_header))
            req.body = body unless body.nil?
          end
        end

        def self.get(path, extra_headers = {})
          logger.debug "Sending GET request to Candlepin: #{path}"
          conn = CandlepinResource.faraday_connection(path_with_cp_prefix(path))
          conn.get(path_with_cp_prefix(path)) do |req|
            req.headers.merge!(extra_headers.merge!(default_request_headers))
          end
        end

        def self.put(path, body)
          logger.debug "Sending PUT request to Candlepin: #{path}"
          conn = CandlepinResource.faraday_connection(path_with_cp_prefix(path))
          conn.put(path_with_cp_prefix(path)) do |req|
            req.headers.merge!({:accept => :json, :content_type => :json}.merge(User.cp_oauth_header))
            req.body = body
          end
        end

        def self.path_with_cp_prefix(path)
          CandlepinResource.prefix + path
        end

        def self.default_request_headers
          @default_request_headers ||= User.cp_oauth_header.merge(accept: :json)
        end
      end
    end
  end
end
