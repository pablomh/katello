require 'net/http'
require 'uri'
require 'openssl'
require 'json'

module Proxy
  module PulpcoreReplicate
    # Generic Pulp REST transport: connection pooling, mTLS, pagination.
    # No Pulp domain knowledge (upstream-pulps, distributions, labels) lives here.
    class HttpTransport
      def initialize(pulp_url:, username: nil, password: nil, ssl_ca_file: nil, ssl_client_cert: nil, ssl_client_key: nil)
        @pulp_url = pulp_url.to_s.sub(%r{/$}, '')
        @username = username
        @password = password
        @ssl_ca_file = ssl_ca_file
        @ssl_client_cert = pem_content(ssl_client_cert)
        @ssl_client_key = pem_content(ssl_client_key)
        @connections = {}
      end

      def get(path)
        request(:get, path)
      end

      def post(path, body = {})
        request(:post, path, body)
      end

      def patch(path, body = {})
        request(:patch, path, body)
      end

      def page_all(path)
        results = []
        url = path
        while url
          data = get(url)
          break unless data.is_a?(Hash)
          results.concat(data['results'] || [])
          url = data['next']
          url = URI.parse(url).request_uri if url&.start_with?('http')
        end
        results
      end

      private

      def request(method, path, body = nil)
        uri = URI.join("#{@pulp_url}/", path.sub(%r{^/}, ''))
        http = connection_for(uri)
        klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method)
        req = klass.new(uri.request_uri)
        req.basic_auth(@username, @password) if @username
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body) if body
        parse(http.request(req))
      end

      def connection_for(uri)
        key = "#{uri.scheme}://#{uri.host}:#{uri.port}"
        conn = @connections[key]
        return conn if conn&.started?
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 10
        http.read_timeout = 120
        http.keep_alive_timeout = 30
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.ca_file = @ssl_ca_file if @ssl_ca_file
        if @ssl_client_cert && @ssl_client_key
          http.cert = OpenSSL::X509::Certificate.new(@ssl_client_cert)
          http.key = OpenSSL::PKey.read(@ssl_client_key)
        end
        http.start
        @connections[key] = http
      end

      def pem_content(value)
        return if value.nil? || value.to_s.empty?
        path = value.to_s
        return File.read(path) if path.start_with?('/') && File.exist?(path)
        value
      end

      def parse(response)
        code = response.code.to_i
        fail HttpError.new(code, response.body) unless (200..299).cover?(code)
        body = response.body
        return {} if body.nil? || body.empty?
        JSON.parse(body)
      rescue JSON::ParserError
        { 'raw' => response.body, 'code' => response.code }
      end
    end
  end
end
