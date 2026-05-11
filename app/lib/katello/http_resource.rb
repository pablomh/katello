require 'oauth'
require 'cgi'
require 'faraday'
require 'faraday/net_http_persistent'

module Katello
  class HttpResource
    class NetworkException < StandardError
    end

    class RestClientException < StandardError
      attr_reader :service_code, :code

      def initialize(params)
        super params[:message]
        @service_code = params[:service_code]
        @code = params[:code]
      end
    end

    include Katello::Concerns::FilterSensitiveData

    class_attribute :consumer_secret, :consumer_key, :prefix, :site, :default_headers,
                    :ssl_client_cert, :ssl_client_key, :ssl_ca_file

    attr_reader :json

    def initialize(json = {})
      @json = json
    end

    def [](key)
      @json[key]
    end

    def []=(key, value)
      @json[key] = value
    end

    class << self
      [:get, :post, :put, :patch, :delete].each do |method|
        define_method(method) do |*args|
          issue_request(
            method: method,
            path: args.first,
            headers: args.length > 1 ? args.last : nil,
            payload: args.length > 2 ? args[1] : nil
          )
        end
      end

      def logger
        fail NotImplementedError
      end

      def process_response(resp)
        logger.debug "Processing response: #{resp.status}"
        logger.debug filter_sensitive_data(resp.body)
        return resp unless resp.status >= 400
        parsed = {}
        message = "Rest exception while processing the call"
        service_code = ""
        status_code = resp.status.to_s
        begin
          parsed = JSON.parse resp.body
          message = parsed["displayMessage"] if parsed["displayMessage"]
          service_code = parsed["code"] if parsed["code"]
        rescue => error
          logger.error "Error parsing the body: " << error.backtrace.join("\n")
          if %w(404 500 502 503 504).member? resp.status.to_s
            logger.error "Remote server status code " << resp.status.to_s
            raise RestClientException, {:message => error.to_s, :service_code => service_code, :code => status_code}, caller
          else
            raise NetworkException, [resp.status.to_s, resp.body].reject { |s| s.blank? }.join(' ')
          end
        end
        fail RestClientException, {:message => message, :service_code => service_code, :code => status_code}, caller
      end

      def issue_request(method:, path:, headers: {}, payload: nil)
        logger.debug("Resource #{method.upcase} request: #{path}")
        logger.debug "Headers: #{headers.to_json}"
        begin
          logger.debug "Body: #{filter_sensitive_data(payload.to_json)}"
        rescue JSON::GeneratorError, Encoding::UndefinedConversionError
          logger.debug "Body: Error: could not render payload as json"
        end

        conn = faraday_connection(path)
        response = conn.send(method, path) do |req|
          req.headers.merge!(headers) if headers
          req.body = payload if payload
        end

        process_response(response)
      rescue Faraday::ConnectionFailed
        service = path.split("/").second
        raise Errors::ConnectionRefusedException, _("A backend service [ %s ] is unreachable") % service.capitalize
      rescue Faraday::Error => e
        raise_faraday_exception e, path, method.upcase
      end

      def raise_faraday_exception(e, a_path, http_method)
        msg = "#{name}: #{e.message} (#{http_method} #{a_path})"
        raise RestClientException, { message: msg, service_code: '', code: e.response&.dig(:status).to_s }
      end

      def join_path(*args)
        args.inject("") do |so_far, current|
          so_far << '/' if (!so_far.empty? && so_far[so_far.length - 1].chr != '/') || current[0].chr != '/'
          so_far << current.strip
        end
      end

      def faraday_connection(path = '')
        url = self.site
        timeout = SETTINGS[:katello][:rest_client_timeout]

        oauth_header = nil
        if self.consumer_key && self.consumer_secret
          full_url = url + path
          oauth_header = build_oauth_header(full_url, :get)
        end

        Faraday.new(url: url) do |f|
          f.options.open_timeout = timeout
          f.options.timeout = timeout

          if self.ssl_ca_file
            f.ssl.ca_file = self.ssl_ca_file
          end
          if self.ssl_client_cert
            f.ssl.client_cert = self.ssl_client_cert
          end
          if self.ssl_client_key
            f.ssl.client_key = self.ssl_client_key
          end

          f.request :authorization, 'OAuth', oauth_header if oauth_header

          f.adapter :net_http_persistent
        end
      end

      def build_oauth_header(url, method)
        params = { :site => self.site,
                   :http_method => method,
                   :request_token_path => "",
                   :authorize_path => "",
                   :access_token_path => "" }
        params[:ca_file] = self.ssl_ca_file unless self.ssl_ca_file.nil?

        consumer = OAuth::Consumer.new(self.consumer_key, self.consumer_secret, params)
        request = Net::HTTP::Get.new(url)
        consumer.sign!(request)
        request['Authorization']
      end

      def hash_to_query(query_parameters)
        "?#{URI.encode_www_form(query_parameters)}"
      end
    end
  end
end
