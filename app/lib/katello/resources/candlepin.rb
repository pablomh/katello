require_relative 'candlepin/pooled_transport'

module Katello
  module Resources
    module Candlepin
      TOTAL_COUNT_HEADER = :x_total_count # as parsed by rest_client

      class CandlepinResource < HttpResource
        class_attribute :use_persistent_connection, default: true

        cfg = SETTINGS[:katello][:candlepin]
        url = cfg[:url]
        uri = URI.parse(url)
        self.prefix = uri.path
        self.site = "#{uri.scheme}://#{uri.host}:#{uri.port}"
        self.consumer_secret = cfg[:oauth_secret]
        self.consumer_key = cfg[:oauth_key]
        self.ssl_ca_file = ::Cert::Certs.backend_ca_cert_file(:candlepin)

        class << self
          def persistent_connection_enabled?
            use_persistent_connection && Setting[:candlepin_pooled_http_enabled]
          end

          def persistent_http_client
            @persistent_http_client ||= Candlepin::PooledTransport::PersistentHttpClient.new(
              site: site,
              ca_file_resolver: method(:current_ssl_ca_file),
              pool_size: persistent_pool_size,
              logger: logger
            )
          end

          def persistent_transport
            @persistent_transport ||= Candlepin::PooledTransport::PersistentTransport.new(
              self,
              pooled_http_client: persistent_http_client
            )
          end

          def rest_client_transport
            @rest_client_transport ||= Candlepin::PooledTransport::RestClientTransport.new(self)
          end

          def reset_persistent_http!
            @persistent_transport = nil
            @rest_client_transport = nil
            @persistent_http_client&.reset!
            @persistent_http_client = nil
          end

          def process_response(response)
            debug_level = response.code >= 400 ? :error : :debug
            logger.send(debug_level) { "Candlepin request #{response.headers[:x_candlepin_request_uuid]} returned with code #{response.code}" }
            super
          end

          def raise_rest_client_exception(error, path, http_method)
            # this differentiates between Tomcat returning a 404 (candlepin is down or not deployed)
            # vs a 404 from Candlepin itself
            unless error&.response&.headers&.dig(:x_version)
              fail ::Katello::Errors::CandlepinNotRunning
            end

            super
          end

          def issue_request(method:, path:, headers: {}, payload: nil)
            log_candlepin_request(method, path, headers, payload)
            process_response(transport_for(payload).call(method: method, path: path, headers: headers, payload: payload))
          rescue RestClient::Exception => e
            raise_rest_client_exception(e, path, method.to_s.upcase)
          rescue Errno::ECONNREFUSED
            service = path.split("/").second
            raise Errors::ConnectionRefusedException,
              _("A backend service [ %s ] is unreachable") % service.capitalize
          rescue Net::HTTP::Persistent::Error => e
            if e.message.include?('connection refused')
              raise Errors::ConnectionRefusedException, _("A backend service [ Candlepin ] is unreachable")
            end
            raise
          rescue Net::OpenTimeout, Net::ReadTimeout => e
            exception = RestClient::RequestTimeout.allocate
            exception.instance_variable_set(:@message, e.message)
            raise_rest_client_exception(exception, path, method.to_s.upcase)
          end

          def current_ssl_ca_file
            ::Cert::Certs.backend_ca_cert_file(:candlepin)
          end

          def update_content_overrides_for(resource_path, content_overrides)
            attrs_to_delete = []
            attrs_to_update = []

            content_overrides.each do |content_override|
              if content_override[:value]
                attrs_to_update << content_override
              else
                attrs_to_delete << content_override
              end
            end

            if attrs_to_update.present?
              result = put(join_path(resource_path, 'content_overrides'),
                           attrs_to_update.to_json,
                           default_headers)
            end

            if attrs_to_delete.present?
              result = issue_request(
                method: :delete,
                path: join_path(resource_path, 'content_overrides'),
                headers: default_headers,
                payload: attrs_to_delete.to_json
              )
            end

            result
          end

          private

          def persistent_pool_size
            [ENV.fetch('FOREMAN_PUMA_THREADS_MAX', ENV.fetch('RAILS_MAX_THREADS', 5)).to_i, 1].max
          end

          def issue_request_via_rest_client(method:, path:, headers: {}, payload: nil)
            client = rest_client(Katello::HttpResource::REQUEST_MAP.fetch(method), method, path)
            args = [method, payload, headers].compact
            process_response(client.public_send(*args))
          end

          def transport_for(payload)
            # Multipart/file uploads still rely on RestClient. Those callers
            # pass Hash payloads while simple string JSON bodies can use the pool.
            return rest_client_transport if payload.is_a?(Hash) || !persistent_connection_enabled?

            persistent_transport
          end

          def log_candlepin_request(method, path, headers, payload)
            logger.debug { "Candlepin #{method.upcase} request: #{path}" }
            logger.debug { "Headers: #{headers.to_json}" } if headers.present?
            return unless payload

            logger.debug do
              body = payload.is_a?(String) ? payload : payload.to_json
              "Body: #{filter_sensitive_data(body)}"
            rescue JSON::GeneratorError, Encoding::UndefinedConversionError
              "Body: Error: could not render payload as json"
            end
          end
        end

        def self.logger
          ::Foreman::Logging.logger('katello/cp_rest')
        end

        def self.default_headers(uuid = nil)
          # There are cases where virt-who needs to act on behalf of hypervisors it is managing.
          # If the uuid is specified, then that consumer is used in the headers rather than the
          # virt-who consumer uuid.
          # Current example is creating a hypervisor that in turn needs to get compliance.
          if !uuid.nil? && User.consumer?
            cp_oauth_header = { 'cp-consumer' => uuid }
          else
            cp_oauth_header = User.cp_oauth_header
          end

          headers = {'accept' => 'application/json',
                     'accept-language' => I18n.locale,
                     'content-type' => 'application/json'}

          request_id = ::Logging.mdc['request']
          headers['X-Correlation-ID'] = request_id if request_id

          headers.merge!(cp_oauth_header)
        end

        def self.name_to_key(a_name)
          a_name.tr(' ', '_')
        end

        def self.included_list(included)
          included.map { |value| "include=#{value}" }.join('&')
        end

        def self.fetch_paged(page_size = -1)
          if page_size == -1
            page_size = SETTINGS[:katello][:candlepin][:bulk_load_size]
          end
          page = 0
          content = []
          loop do
            page += 1
            data = yield("per_page=#{page_size}&page=#{page}")
            content.concat(data)
            break if data.size < page_size
          end
          content
        end
      end

      class UpstreamCandlepinResource < CandlepinResource
        extend ::Katello::Util::HttpProxy

        self.use_persistent_connection = false
        self.prefix = '/subscription'

        class << self
          delegate :[], to: :json_resource

          def default_headers(uuid = nil)
            super(uuid).except('cp-user', 'cp-consumer')
          end

          def resource(options = {}, url: self.site + self.path, client_cert: self.client_cert, client_key: self.client_key, ca_file: nil)
            cert_store = OpenSSL::X509::Store.new
            cert_store.add_file(ca_file) if ca_file

            if proxy&.cacert&.present?
              Foreman::Util.add_ca_bundle_to_store(proxy.cacert, cert_store)
            end
            RestClient::Resource.new(url,
                                     :ssl_client_cert => OpenSSL::X509::Certificate.new(client_cert),
                                     :ssl_client_key => OpenSSL::PKey::RSA.new(client_key),
                                     :ssl_cert_store => cert_store,
                                     :verify_ssl => ca_file ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE,
                                     :open_timeout => Setting[:manifest_refresh_timeout],
                                     :timeout => Setting[:manifest_refresh_timeout],
                                     :proxy => self.proxy_uri,
                                     **options
                                    )
          end

          def json_resource(options = {}, url: self.site + self.path, client_cert: self.client_cert, client_key: self.client_key, ca_file: nil)
            options.deep_merge!(headers: self.default_headers)
            resource(options, url: url, client_cert: client_cert, client_key: client_key, ca_file: ca_file)
          end

          def rest_client(_http_type = nil, method = :get, path = self.path)
            # No oauth upstream
            self.consumer_secret = nil
            self.consumer_key = nil

            resource({ http_method: method }, url: self.site + path, client_cert: client_cert, client_key: client_key, ca_file: nil)
          end

          def issue_request(method:, path:, headers: {}, payload: nil)
            log_candlepin_request(method, path, headers, payload)
            issue_request_via_rest_client(method: method, path: path, headers: headers, payload: payload)
          rescue RestClient::Exception => e
            raise_rest_client_exception(e, path, method.to_s.upcase)
          rescue Errno::ECONNREFUSED
            service = path.split("/").second
            raise Errors::ConnectionRefusedException,
              _("A backend service [ %s ] is unreachable") % service.capitalize
          end

          def reset_connection!
            @upstream_owner_ids = nil
          end

          def client_cert
            upstream_id_cert['cert']
          end

          def client_key
            upstream_id_cert['key']
          end

          def upstream_api_uri
            URI.parse(upstream_consumer['apiUrl'])
          end

          def site
            default_port = (upstream_api_uri.scheme == 'https') ? 443 : 80
            upstream_site = "#{upstream_api_uri.scheme}://#{upstream_api_uri.host}"
            (upstream_api_uri.port == default_port) ? upstream_site : "#{upstream_site}:#{upstream_api_uri.port}"
          end

          def upstream_id_cert
            unless upstream_consumer && upstream_consumer['idCert'] && upstream_consumer['idCert']['cert'] && upstream_consumer['idCert']['key']
              Rails.logger.error "Upstream identity certificate not available"
              fail _("Upstream identity certificate not available")
            end
            upstream_consumer['idCert']
          end

          def upstream_owner_id
            org_id = Organization.current&.id
            @upstream_owner_ids ||= {}
            @upstream_owner_ids[org_id] ||= JSON.parse(Katello::Resources::Candlepin::UpstreamConsumer.resource.get.body)['owner']['key']
          rescue RestClient::Exception => e
            Rails.logger.error "Unable to find upstream owner for consumer"
            raise e
          end

          def upstream_consumer_id
            upstream_consumer['uuid']
          end

          def upstream_consumer
            fail _("Current organization not set.") unless Organization.current
            upstream_consumer = Organization.current.owner_details['upstreamConsumer']
            fail Katello::Errors::NoManifestImported unless upstream_consumer

            upstream_consumer
          end
        end # class << self
      end # UpstreamCandlepinResource

      module AdminResource
        def path
          "#{self.prefix}/admin"
        end
      end

      module ConsumerResource
        def path(id = nil)
          "#{self.prefix}/consumers/#{id}"
        end
      end

      module OwnerResource
        def path(id = nil)
          "#{self.prefix}/owners/#{id}"
        end
      end

      module PoolResource
        def path(id = nil, owner_label = nil)
          if owner_label && id
            "#{prefix}/owners/#{owner_label}/pools/#{id}"
          elsif owner_label
            "#{prefix}/owners/#{owner_label}/pools/"
          else
            "#{prefix}/pools/#{id}"
          end
        end
      end
    end
  end
end
