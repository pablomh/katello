namespace :katello do
  desc "One-time migration: label a capsule's existing content as managed by replicate() for an organization. SMART_PROXY_ID=1 ORGANIZATION_ID=1"
  task :adopt_capsule_replication => ['environment'] do
    smart_proxy = ::SmartProxy.unscoped.find(ENV['SMART_PROXY_ID'])
    organization = ::Organization.find(ENV['ORGANIZATION_ID'])

    repos = ::Katello::SmartProxyHelper.new(smart_proxy).repositories_available_to_capsule(nil, nil).
      select { |repo| ::Katello::Pulp3::Replication.content_organization(repo) == organization }
    replicable, = ::Katello::Pulp3::Replication.replicable_repos_for(smart_proxy, repos)

    if replicable.empty?
      puts "No replicate()-eligible repositories found for #{organization.label} on #{smart_proxy.name}."
      next
    end

    repo_by_base_path = replicable.index_by do |repo|
      ::Katello::Pulp3::Replication.distribution_path_for(smart_proxy, repo)
    end

    # One lookup_distributions(base_path__in: ...) call per content type instead of one
    # read_distribution call per repo - each content type shares a single distributions API.
    distributions = {}
    repo_by_base_path.group_by { |_base_path, repo| repo.content_type }.each_value do |pairs|
      base_paths = pairs.map(&:first)
      representative_repo = pairs.first.last
      representative_repo.backend_service(::SmartProxy.pulp_primary).lookup_distributions(base_path__in: base_paths).each do |dist|
        distributions[dist.base_path] = dist.name if dist.name
      end
    end

    skipped = repo_by_base_path.size - distributions.size
    puts "Skipping #{skipped} repository(ies) with no synced distribution on the primary Pulp yet." if skipped.positive?

    if distributions.empty?
      puts "Nothing to adopt for #{organization.label} on #{smart_proxy.name}."
      next
    end

    protected_base_paths = distributions.keys.select do |base_path|
      ::Katello::Pulp3::Replication.protected_content?(repo_by_base_path[base_path])
    end
    content_guard_href = ::Katello::Pulp3::Api::ContentGuard.new(smart_proxy).refresh&.pulp_href if protected_base_paths.any?

    # Set katello_repo_id directly at adoption time instead of relying on the next
    # replicate() cycle's label copy-down - that backfill is fragile (skipped entirely
    # if the org is never resynced, or replicate uses a NODELETE-style policy).
    repository_ids = distributions.keys.each_with_object({}) do |base_path, hash|
      hash[base_path] = repo_by_base_path[base_path].id.to_s
    end

    api = ::Katello::Pulp3::Api::UpstreamPulp.new(smart_proxy)
    pulp_href = ::Katello::Pulp3::Replication.ensure_upstream_pulp!(api, organization)
    response = api.adopt(pulp_href, {
                           distributions: distributions,
                           protected_base_paths: protected_base_paths,
                           content_guard_href: content_guard_href,
                           repository_ids: repository_ids,
                         })

    task = ::Katello::Pulp3::Task.new(smart_proxy, 'task' => response.task)
    timeout = Setting[:sync_total_timeout] || 3600
    start_time = Time.now
    until task.done?
      fail "Adoption task timed out after #{(Time.now - start_time).to_i} seconds." if Time.now - start_time > timeout
      sleep 1
      task.poll
    end

    if task.error
      puts "Adoption task failed: #{task.error}"
      next
    end

    conflicts = Array(task.task_data.dig(:result, :conflicts))
    if conflicts.any?
      puts "Adoption completed for #{distributions.size} distribution(s), but #{conflicts.size} object(s) are " \
           "already managed by a different UpstreamPulp and were left untouched:"
      conflicts.each { |conflict| puts "  #{conflict[:base_path]} (#{conflict[:object]}): owned by UpstreamPulp #{conflict[:owner]}" }
    else
      puts "Adoption task completed for #{distributions.size} distribution(s)."
    end
  end
end
