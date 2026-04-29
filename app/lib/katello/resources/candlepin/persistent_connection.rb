module Katello
  module Resources
    module Candlepin
      # Provides persistent HTTP connection pooling for CandlepinResource.
      #
      # Maintains one TCP+TLS connection per Puma thread via Thread.current,
      # reused across all Candlepin calls within that thread. This eliminates
      # per-request TCP+TLS handshake overhead using only stdlib Net::HTTP.
      #
      # Include in CandlepinResource; set `self.use_persistent_connection = false`
      # in subclasses that connect to different servers (e.g. UpstreamCandlepinResource).
      module PersistentConnection
        extend ActiveSupport::Concern

        # Response wrapper that preserves the RestClient::Response contract.
        #
        # Inherits from String (like RestClient::Response) so that
        # MultiJson.load(exception.response) works in CandlepinError.from_exception.
        class PooledResponse < String
          attr_reader :code, :headers, :request

          def initialize(net_response, url:)
            super(net_response.body || '')
            @code = net_response.code.to_i
            @headers = {}
            net_response.each_header do |k, v|
              @headers[k.downcase.tr('-', '_').to_sym] = v
            end
            @request = OpenStruct.new(url: url)
          end

          def body
            to_s
          end
        end

        THREAD_KEY = :katello_candlepin_persistent_http

        included do
          class_attribute :use_persistent_connection, default: true
        end

        class_methods do
          def persistent_connection
            conn = Thread.current[THREAD_KEY]

            if conn&.started?
              reg_logger.debug("candlepin_pool connection=REUSED")
            else
              conn&.finish rescue nil
              uri = URI.parse(SETTINGS[:katello][:candlepin][:url])
              conn = Net::HTTP.new(uri.host, uri.port)
              conn.use_ssl = (uri.scheme == 'https')
              conn.verify_mode = OpenSSL::SSL::VERIFY_PEER
              conn.ca_file = ssl_ca_file if ssl_ca_file
              conn.open_timeout = SETTINGS[:katello][:rest_client_timeout]
              conn.read_timeout = SETTINGS[:katello][:rest_client_timeout]
              conn.keep_alive_timeout = 30
              conn.start
              Thread.current[THREAD_KEY] = conn
              reg_logger.debug("candlepin_pool connection=NEW")
            end

            conn
          end

          def issue_request(method:, path:, headers: {}, payload: nil)
            return super unless use_persistent_connection

            logger.debug("Pooled Candlepin #{method.upcase} request: #{path}")

            url = self.site + path
            uri = URI.parse(url)

            request = Katello::HttpResource::REQUEST_MAP[method].new(uri)

            # OAuth signing — same consumer/secret as rest_client(), applied to the actual request
            consumer = OAuth::Consumer.new(
              self.consumer_key, self.consumer_secret,
              site: self.site, http_method: method,
              request_token_path: '', authorize_path: '', access_token_path: ''
            )
            consumer.sign!(request)

            (headers || {}).each { |k, v| request[k.to_s] = v }

            if payload
              request.body = payload
              request.content_type = 'application/json' unless request['Content-Type']
            end

            begin
              logger.debug "Body: #{filter_sensitive_data(payload.to_json)}"
            rescue JSON::GeneratorError, Encoding::UndefinedConversionError
              logger.debug "Body: Error: could not render payload as json"
            end if payload

            retried = false
            begin
              net_response = persistent_connection.request(request)
            rescue IOError, Errno::EPIPE, Errno::ECONNRESET => e
              # Stale connection (server closed idle socket) — reconnect once
              raise if retried
              retried = true
              Thread.current[THREAD_KEY] = nil
              retry
            end

            response = PooledResponse.new(net_response, url: url)

            if response.code >= 400
              raise_pooled_error(response, path, method)
            end

            process_response(response)
          rescue Errno::ECONNREFUSED
            service = path.split("/").second
            raise Errors::ConnectionRefusedException,
              _("A backend service [ %s ] is unreachable") % service.capitalize
          end

          private

          def reg_logger
            ::Foreman::Logging.logger('registration')
          end

          def raise_pooled_error(response, path, method)
            unless response.headers[:x_version]
              fail ::Katello::Errors::CandlepinNotRunning
            end

            exception_class = RestClient::Exceptions::EXCEPTIONS_MAP.fetch(
              response.code, RestClient::ExceptionWithResponse
            )
            exception = exception_class.new(response, response.code)

            raise_rest_client_exception(exception, path, method.to_s.upcase)
          end
        end
      end
    end
  end
end
