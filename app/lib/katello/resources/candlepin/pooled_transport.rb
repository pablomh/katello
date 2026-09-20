require 'net/http/persistent'
require 'ostruct'

module Katello
  module Resources
    module Candlepin
      module ResponseAdapter
        module_function

        def body(response)
          return '' if response.nil?

          response.body.to_s
        end

        def code(response)
          response.code.to_i
        end

        def content_type(response)
          headers = response.respond_to?(:headers) ? response.headers : {}
          headers[:content_type] || headers['content-type'] || 'application/json'
        end
      end

      module PooledTransport
        CONTENT_TYPE_MAP = {
          json: 'application/json',
          xml: 'application/xml',
        }.freeze

        class Response
          attr_reader :code, :headers, :request, :body

          def initialize(net_response, url:)
            @body = net_response.body.to_s
            @code = net_response.code.to_i
            @headers = {}
            net_response.each_header do |key, value|
              @headers[key.downcase.tr('-', '_').to_sym] = value
            end
            @request = OpenStruct.new(url: url)
          end
        end

        class RequestSigner
          def initialize(resource_class)
            @resource_class = resource_class
            @consumers = {}
            @consumers_mutex = Mutex.new
          end

          def authorization_header(method:, uri:)
            request = Katello::HttpResource::REQUEST_MAP.fetch(method).new(uri.to_s)
            consumer_for(method).sign!(request)
            request['Authorization']
          end

          private

          # OAuth::Consumer#sign! only reads the signing key/secret and the request
          # object's own method/URI; the params below (site, ca_file, ...) are only
          # consulted as fallbacks that never trigger since we always sign a request
          # built from a full absolute URL. Still, key the cache on (method, ca_file)
          # rather than assume that forever, so a CA rotation or unexpected method
          # rebuilds the consumer instead of silently reusing stale params.
          def consumer_for(method)
            ca_file = @resource_class.current_ssl_ca_file
            key = [method, ca_file]

            @consumers_mutex.synchronize do
              @consumers[key] ||= build_consumer(method, ca_file)
            end
          end

          def build_consumer(method, ca_file)
            params = {
              site: @resource_class.site,
              http_method: method,
              request_token_path: "",
              authorize_path: "",
              access_token_path: "",
            }
            params[:ca_file] = ca_file if ca_file

            OAuth::Consumer.new(@resource_class.consumer_key, @resource_class.consumer_secret, params)
          end
        end

        class RestClientTransport
          def initialize(resource_class, signer: RequestSigner.new(resource_class))
            @resource_class = resource_class
            @signer = signer
          end

          def call(method:, path:, headers:, payload:)
            url = @resource_class.site + path
            uri = URI.parse(url)
            client = resource(url: url, method: method, authorization_header: @signer.authorization_header(method: method, uri: uri))

            dispatch(client: client, method: method, headers: headers || {}, payload: payload)
          end

          private

          def resource(url:, method:, authorization_header:)
            options = {
              headers: { 'Authorization' => authorization_header },
              open_timeout: SETTINGS[:katello][:rest_client_timeout],
              timeout: SETTINGS[:katello][:rest_client_timeout],
            }

            ca_file = @resource_class.current_ssl_ca_file
            options[:ssl_ca_file] = ca_file if ca_file
            options[:ssl_client_cert] = @resource_class.ssl_client_cert if @resource_class.ssl_client_cert
            options[:ssl_client_key] = @resource_class.ssl_client_key if @resource_class.ssl_client_key

            RestClient::Resource.new(url, options.merge(http_method: method))
          end

          def dispatch(client:, method:, headers:, payload:)
            case method
            when :get
              client.get(headers)
            when :delete
              client.options[:payload] = payload if payload.present?
              client.delete(headers)
            else
              client.public_send(method, payload, headers)
            end
          end
        end

        class PersistentHttpClient
          DEFAULT_IDLE_TIMEOUT = 5
          DEFAULT_MAX_REQUESTS = 500

          def initialize(site:, ca_file_resolver:, pool_size:, logger:)
            @site = site
            @ca_file_resolver = ca_file_resolver
            @pool_size = pool_size
            @logger = logger
            @mutex = Mutex.new
          end

          def request(uri, request)
            with_connection_error_reset do
              client_for_current_key.request(uri, request)
            end
          end

          def reset!
            @mutex.synchronize do
              previous_client = @client
              @client = nil
              @client_key = nil
              shutdown(previous_client)
            end
          end

          private

          def client_for_current_key
            key = current_key
            if @client && @client_key == key
              @logger.debug("Reusing pooled Candlepin HTTP client for #{@site}")
              return @client
            end

            @mutex.synchronize do
              if @client && @client_key == key
                @logger.debug("Reusing pooled Candlepin HTTP client for #{@site}")
                return @client
              end

              previous_client = @client
              @client = nil
              @client_key = nil

              @logger.info("Creating pooled Candlepin HTTP client for #{@site} with pool_size=#{@pool_size}")
              @client_key = key
              @client = build_client(ca_file: current_ssl_ca_file)
              shutdown(previous_client)
              @client
            end
          end

          def build_client(ca_file:)
            Net::HTTP::Persistent.new(name: 'candlepin', pool_size: @pool_size).tap do |http|
              http.ca_file = ca_file if ca_file
              http.open_timeout = SETTINGS[:katello][:rest_client_timeout]
              http.read_timeout = SETTINGS[:katello][:rest_client_timeout]
              # Reap locally before Candlepin closes the socket on us, and
              # rotate long-lived clients so stale descriptors do not accumulate.
              http.idle_timeout = configured_idle_timeout if http.respond_to?(:idle_timeout=)
              http.max_requests = configured_max_requests if http.respond_to?(:max_requests=)
            end
          end

          def current_key
            [@site, current_ssl_ca_freshness_token]
          end

          def current_ssl_ca_file
            @ca_file_resolver.call
          end

          def current_ssl_ca_freshness_token
            path = current_ssl_ca_file
            return [nil, nil] if path.blank?

            stat = File.stat(path)
            [path, stat.size, stat.mtime.to_f]
          rescue StandardError
            [path, nil]
          end

          def shutdown(http)
            http.shutdown if http.respond_to?(:shutdown)
          rescue StandardError
            nil
          end

          def configured_max_requests
            [ENV.fetch('KATELLO_CANDLEPIN_PERSISTENT_MAX_REQUESTS', DEFAULT_MAX_REQUESTS).to_i, 1].max
          end

          def configured_idle_timeout
            [ENV.fetch('KATELLO_CANDLEPIN_PERSISTENT_IDLE_TIMEOUT', DEFAULT_IDLE_TIMEOUT).to_i, 1].max
          end

          def with_connection_error_reset
            yield
          rescue Net::HTTP::Persistent::Error, Errno::ECONNRESET, Errno::EPIPE, IOError => e
            @logger.info("Resetting pooled Candlepin HTTP client for #{@site} after #{e.class}: #{e.message}")
            reset!
            raise
          end
        end

        class PersistentTransport
          def initialize(resource_class, pooled_http_client:, signer: RequestSigner.new(resource_class))
            @resource_class = resource_class
            @pooled_http_client = pooled_http_client
            @signer = signer
          end

          def call(method:, path:, headers:, payload:)
            url = @resource_class.site + path
            uri = URI.parse(url)
            request = build_request(method: method, uri: uri, headers: headers || {}, payload: payload)
            response = Response.new(@pooled_http_client.request(uri, request), url: url)
            raise_for_error_response(response)
            response
          end

          private

          def build_request(method:, uri:, headers:, payload:)
            request = Katello::HttpResource::REQUEST_MAP.fetch(method).new(uri)
            request['Authorization'] = @signer.authorization_header(method: method, uri: uri)

            headers.each do |key, value|
              request[normalize_header_name(key)] = CONTENT_TYPE_MAP[value] || value.to_s
            end

            if payload
              request.body = payload
              request.content_type = 'application/json' unless request['Content-Type']
            end

            request
          end

          def normalize_header_name(key)
            key.to_s.tr('_', '-')
          end

          def raise_for_error_response(response)
            return unless response.code == 304 || response.code >= 400

            exception_class = RestClient::Exceptions::EXCEPTIONS_MAP.fetch(response.code, RestClient::ExceptionWithResponse)
            fail exception_class.new(response, response.code)
          end
        end
      end
    end
  end
end
