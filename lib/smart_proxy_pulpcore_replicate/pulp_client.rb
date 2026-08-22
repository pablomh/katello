require 'json'
require 'cgi'
require 'time'
require 'smart_proxy_pulpcore_replicate/http_transport'

module Proxy
  module PulpcoreReplicate
    class HttpError < StandardError
      NAME_CONFLICT_PATTERN = /name.*?(must\ be\ unique|code=['"]unique)/mix

      attr_reader :status

      def initialize(status, body)
        @status = status.to_i
        super("Pulp #{status}: #{body}")
      end

      def not_found?
        status == 404
      end

      # Two Capsule syncs racing to create the same org's UpstreamPulp.
      def name_conflict?
        status == 400 && message.match?(NAME_CONFLICT_PATTERN)
      end
    end

    # Foreman Proxy is Sinatra without ActiveSupport. JSON on the wire (and
    # JSON.parse of Pulp responses) uses string keys. Do not call
    # Hash#with_indifferent_access or read symbol keys from JSON payloads.
    class PulpClient
      DEFAULT_UPSTREAM_NAME = 'katello-satellite'.freeze
      PLUGIN_PREFIXES = {
        'rpm' => { distro: 'rpm/rpm', remote: 'rpm/rpm', repo: 'rpm/rpm' },
        'file' => { distro: 'file/file', remote: 'file/file', repo: 'file/file' },
        'container' => { distro: 'container/container', remote: 'container/container', repo: 'container/container' },
        'python' => { distro: 'python/pypi', remote: 'python/python', repo: 'python/python' },
      }.freeze
      REPLICATE_PLUGINS = %w[rpm container].freeze
      BASE_PATH_FILTER_MAX = 8

      UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i
      REMOTE_SETTINGS_BLOCKLIST = %w[policy client_cert client_key rate_limit].freeze
      RECONCILE_KEYS = %w[base_url api_root policy tls_validation client_cert client_key ca_cert username password q_select
                          total_timeout connect_timeout sock_connect_timeout sock_read_timeout].freeze
      REDACTABLE_KEYS = %w[client_cert client_key ca_cert username password].freeze
      FORCE_SYNC_LABEL = 'katello_force_sync'.freeze
      UPSTREAM_LABEL = 'UpstreamPulp'.freeze
      ADOPTED_LABEL = 'katello_adopted'.freeze

      def initialize(settings = {})
        @transport = HttpTransport.new(
          pulp_url: settings[:pulp_url] || settings['pulp_url'] || 'https://localhost',
          username: settings[:username] || settings['username'],
          password: settings[:password] || settings['password'],
          ssl_ca_file: settings[:ssl_ca_file] || settings['ssl_ca_file'],
          ssl_client_cert: settings[:ssl_client_cert] || settings['ssl_client_cert'],
          ssl_client_key: settings[:ssl_client_key] || settings['ssl_client_key']
        )
      end

      def self.upstream_pk(upstream_href)
        href = upstream_href.to_s
        match = href[UUID_RE]
        fail ArgumentError, "UpstreamPulp href has no UUID: #{href}" if match.nil?
        match
      end

      def self.string_keys(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, val), out| out[key.to_s] = string_keys(val) }
        when Array
          value.map { |item| string_keys(item) }
        else
          value
        end
      end

      def self.attr_drift(existing, attrs)
        existing = string_keys(existing || {})
        drift = {}
        string_keys(attrs || {}).each do |key, value|
          next unless RECONCILE_KEYS.include?(key)
          next if value.nil?
          stored = existing[key]
          next if REDACTABLE_KEYS.include?(key) && (stored.nil? || stored.to_s.empty?)
          drift[key] = value unless values_equal?(stored, value)
        end
        drift
      end

      def self.values_equal?(stored, desired)
        stored.to_s == desired.to_s
      end

      def self.force_sync_labels(existing_labels, stamp)
        labels = existing_labels.is_a?(Hash) ? string_keys(existing_labels) : {}
        labels[FORCE_SYNC_LABEL] = stamp
        labels
      end

      def replicate(payload)
        payload = self.class.string_keys(payload)
        server = create_or_get_upstream_pulp(payload)
        stamp_unlabeled(server, payload) unless reconciled?(server)
        server = bump_requires_syncing(server) if force_sync?(payload)
        body = {}
        q_select = payload['q_select']
        body['q_select'] = q_select unless q_select.nil?
        post("#{server['pulp_href']}replicate/", body)
      end

      def adopt(server, base_paths, payload = {})
        return if server.nil? || base_paths.nil? || base_paths.empty?
        payload = self.class.string_keys(payload)
        upstream_href = server['pulp_href']
        pk = self.class.upstream_pk(upstream_href)
        label = { UPSTREAM_LABEL => pk }
        normalized = Array(base_paths).map { |path| normalize_path(path) }
        extra = remote_patch(payload)
        PLUGIN_PREFIXES.each_key do |plugin|
          stamp_objects(plugin, normalized, label, extra)
        rescue HttpError => e
          raise unless e.not_found?
        end
        mark_adopted(upstream_href, server['pulp_labels'])
      end

      def create_or_get_upstream_pulp(payload)
        payload = self.class.string_keys(payload)
        name = upstream_name(payload)
        attrs = upstream_attrs(payload)
        existing = find_upstream_pulp(name)
        existing ? apply_drift(existing, attrs) : create_upstream_pulp(name, attrs)
      end

      private

      def find_upstream_pulp(name)
        list_upstream_pulps(name).find { |item| item['name'] == name }
      end

      def apply_drift(existing, attrs)
        drift = self.class.attr_drift(existing, attrs)
        return existing if drift.empty?
        patch(existing['pulp_href'], drift)
        existing.merge(drift)
      end

      def create_upstream_pulp(name, attrs)
        post("/pulp/api/v3/upstream-pulps/", attrs)
      rescue HttpError => e
        raise unless e.name_conflict?
        existing = find_upstream_pulp(name)
        raise e if existing.nil?
        apply_drift(existing, attrs)
      end

      def stamp_unlabeled(server, payload)
        payload = self.class.string_keys(payload)
        upstream_href = server['pulp_href']
        paths = Array(payload['adopt_base_paths']).map { |path| normalize_path(path) }
        return if paths.empty?
        pk = self.class.upstream_pk(upstream_href)
        label = { UPSTREAM_LABEL => pk }
        extra = remote_patch(payload)
        protected = Array(payload['protected_base_paths']).map { |path| normalize_path(path) }
        guard_href = payload['content_guard_href'] || default_content_guard_href if protected.any?

        REPLICATE_PLUGINS.each do |plugin|
          distros = list_distributions(plugin, paths)
          unlabeled = distros.reject { |distro| adopted?(distro, pk) }
          label_and_stamp(plugin, unlabeled, label, extra)
          apply_content_guards_to(distros, protected, guard_href)
        rescue HttpError => e
          raise unless e.not_found?
        end
        mark_adopted(upstream_href, server['pulp_labels'])
      end

      def stamp_objects(plugin, base_paths, label, extra_remote = {})
        prefixes = PLUGIN_PREFIXES[plugin]
        return unless prefixes
        distros = list_distributions(plugin, base_paths)
        matched = distros.select { |distro| adopt_match?(distro, base_paths) }
        label_and_stamp(plugin, matched, label, extra_remote)
      end

      def label_and_stamp(plugin, distros, label, extra_remote)
        distros.each do |distro|
          merge_labels(distro['pulp_href'], distro['pulp_labels'], label)
          merge_labels(distro['repository'], nil, label) if distro['repository']
        end
        stamp_remotes_and_repos(plugin, distros, label, extra_remote)
      end

      def reconciled?(server)
        labels = server['pulp_labels']
        labels.is_a?(Hash) && labels[ADOPTED_LABEL].to_s == 'true'
      end

      def mark_adopted(upstream_href, existing_labels)
        merge_labels(upstream_href, existing_labels, { ADOPTED_LABEL => 'true' })
      rescue HttpError
        nil
      end

      def upstream_name(payload)
        name = payload['upstream_name']
        (name.nil? || name.to_s.empty?) ? DEFAULT_UPSTREAM_NAME : name.to_s
      end

      def stamp_remotes_and_repos(plugin, distros, label, extra_remote)
        names = distros.map { |distro| distro['name'] }.compact
        return if names.empty?
        prefixes = PLUGIN_PREFIXES[plugin]
        page_all("/pulp/api/v3/remotes/#{prefixes[:remote]}/").each do |remote|
          next unless names.include?(remote['name'])
          merge_labels(remote['pulp_href'], remote['pulp_labels'], label, extra_remote)
        end
        page_all("/pulp/api/v3/repositories/#{prefixes[:repo]}/").each do |repo|
          next unless names.include?(repo['name'])
          merge_labels(repo['pulp_href'], repo['pulp_labels'], label)
        end
      end

      def list_distributions(plugin, base_paths)
        prefixes = PLUGIN_PREFIXES[plugin]
        return [] unless prefixes
        collection = "/pulp/api/v3/distributions/#{prefixes[:distro]}/"
        if base_paths.size.between?(1, BASE_PATH_FILTER_MAX)
          base_paths.flat_map do |path|
            page_all("#{collection}?base_path=#{CGI.escape(path)}")
          end
        else
          page_all(collection).select { |distro| adopt_match?(distro, base_paths) }
        end
      end

      def apply_content_guards_to(distros, protected_paths, guard_href)
        return if protected_paths.empty? || guard_href.nil?
        distros.each do |distro|
          path = normalize_path(distro['base_path'])
          next unless protected_paths.include?(path)
          next if distro['content_guard'].to_s == guard_href.to_s
          patch(distro['pulp_href'], 'content_guard' => guard_href)
        end
      end

      def upstream_attrs(payload)
        attrs = {
          'name' => upstream_name(payload),
          'base_url' => payload['satellite_base_url'],
          'api_root' => payload['api_root'] || '/pulp/',
          'policy' => payload['policy'] || 'labeled',
          'tls_validation' => true,
        }
        stored_q = payload['stored_q_select']
        attrs['q_select'] = stored_q if stored_q
        %w[client_cert client_key ca_cert username password].each do |key|
          value = payload[key]
          attrs[key] = value if value
        end
        remote_settings = payload['remote_settings'] || {}
        remote_settings.each do |key, value|
          next if REMOTE_SETTINGS_BLOCKLIST.include?(key.to_s)
          attrs[key.to_s] = value unless value.nil?
        end
        attrs['policy'] = payload['policy'] || 'labeled'
        attrs
      end

      def force_sync?(payload)
        flag = payload['force_sync']
        flag == true || flag.to_s == 'true'
      end

      def bump_requires_syncing(server)
        labels = self.class.force_sync_labels(server['pulp_labels'], Time.now.utc.iso8601(6))
        patched = patch(server['pulp_href'], 'pulp_labels' => labels)
        server.merge('pulp_labels' => labels).merge(patched)
      rescue HttpError
        api_root = server['api_root'].to_s
        api_root = '/pulp/' if api_root.empty?
        patch(server['pulp_href'], 'api_root' => api_root)
        server.merge('api_root' => api_root)
      end

      def remote_patch(payload)
        patch = {}
        cert = payload['remote_client_cert']
        key = payload['remote_client_key']
        policy = payload['remote_download_policy']
        patch['client_cert'] = cert if cert
        patch['client_key'] = key if key
        patch['policy'] = policy if policy && %w[on_demand immediate streamed].include?(policy.to_s)
        remote_settings = payload['remote_settings'] || {}
        %w[total_timeout connect_timeout sock_connect_timeout sock_read_timeout rate_limit].each do |key|
          value = remote_settings[key]
          patch[key] = value unless value.nil?
        end
        patch
      end

      def adopted?(object, upstream_pk)
        labels = object['pulp_labels']
        labels = {} unless labels.is_a?(Hash)
        labels[UPSTREAM_LABEL].to_s == upstream_pk.to_s
      end

      def adopt_match?(object, base_paths)
        path = object['base_path']
        return true if path && base_paths.include?(normalize_path(path))
        url = object['url'].to_s
        return false if url.empty?
        base_paths.any? { |base_path| base_path.to_s.length > 8 && url.include?(base_path) }
      end

      def merge_labels(href, existing_labels, label, extra = {})
        return if href.nil?
        current = existing_labels.is_a?(Hash) ? self.class.string_keys(existing_labels) : {}
        body = { 'pulp_labels' => current.merge(label) }
        extra.each { |key, value| body[key.to_s] = value unless value.nil? }
        patch(href, body)
      end

      def default_content_guard_href
        data = get('/pulp/api/v3/contentguards/certguard/certguard/')
        results = data.is_a?(Hash) ? (data['results'] || []) : Array(data)
        results.first && results.first['pulp_href']
      rescue HttpError => e
        raise unless e.not_found?
        nil
      end

      def list_upstream_pulps(name = DEFAULT_UPSTREAM_NAME)
        data = get("/pulp/api/v3/upstream-pulps/?name=#{CGI.escape(name)}")
        data.is_a?(Hash) ? (data['results'] || []) : Array(data)
      end

      def get(path)
        @transport.get(path)
      end

      def post(path, body = {})
        @transport.post(path, body)
      end

      def patch(path, body = {})
        @transport.patch(path, body)
      end

      def page_all(path)
        @transport.page_all(path)
      end

      def normalize_path(path)
        path.to_s.sub(%r{^/}, '')
      end
    end
  end
end
