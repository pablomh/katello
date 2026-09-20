# RPM Deployment Handoff

This document is the RPM-specific operator handoff for the **direct-upstream** Capsule replicate design.

It is intentionally separate from the containerized handoff so RPM-based deployments can follow a clean, RPM-native procedure.

## Scope

This handoff is for:

- Katello from `/Users/pmendezh/work/Katello/katello/.claude/worktrees/capsule-replicate-direct-upstream`
- pulpcore from `/Users/pmendezh/work/pulp/pulpcore-direct-upstream`

Current scope note:

- direct-upstream replicate is currently intended for yum repositories
- container repositories stay on the classic sync path until Satellite's `/v2/`
  registry token flow has a deliberate Capsule-facing auth design

This handoff is **not** for the proxy-routed bundle.

Do not mix in files from:

- `/Users/pmendezh/work/Katello/katello`
- `/Users/pmendezh/work/Katello/katello/.claude/worktrees/capsule-replicate-pulp-proxy`
- `/Users/pmendezh/work/pulp/pulpcore-replica-remote-credential-split`

## Observed RPM Baseline

Observed host roles in the validated RPM deployment:

- Satellite
- Capsule

Observed package baseline:

- Satellite:
  - `satellite-6.21.0-0.1.stream.el9sat`
  - `katello-5.0.0-0.3.master.el9sat`
  - `python3.12-pulpcore-3.105.15-1.el9pc`
- Capsule:
  - `foreman-proxy-5.1.0-0.1.develop.20260825211617gitc2af3d3.el9sat`
  - `python3.12-pulpcore-3.105.15-1.el9pc`

Observed services were active on both hosts at preflight time.

Initial content baseline in the validated RPM deployment:

- the checked Capsule had no attached lifecycle environments
- `repo_count = 0`

That means the RPM environment was initially a deployment target, not yet a meaningful sync-test target.

Live deployment note from the validated RPM rollout:

- backup root used on both hosts: `/root/direct-upstream-rpm-backup/20260831121559`

## Direct-Upstream Shape On RPM Deployments

For the direct-upstream design, RPM deployments need only:

1. Katello runtime patches on Satellite
2. pulpcore runtime patches on Satellite and Capsules

It does **not** need:

- a custom Foreman Proxy plugin
- `ProxyAPI::PulpcoreReplicate`
- `lib/smart_proxy_pulpcore_replicate*`
- `db/seeds.d/104-proxy.rb`
- any `pulpcore_replicate` feature registration

If any earlier proxy-routed experiment added those pieces, remove them instead of carrying them forward.

## Runtime Paths

Satellite:

- Foreman app root: `/usr/share/foreman`
- Katello gem root: `/usr/share/gems/gems/katello-5.1.0.pre.master`
- pulpcore root: `/usr/lib/python3.12/site-packages/pulpcore`

Capsule:

- Foreman Proxy service: `foreman-proxy.service`
- pulpcore root: `/usr/lib/python3.12/site-packages/pulpcore`

## Backup First

Before patching, create a dated backup directory on each host and copy the currently installed runtime files there.

At minimum, back up:

- Satellite Katello files under `/usr/share/gems/gems/katello-5.1.0.pre.master`
- Satellite pulpcore files under `/usr/lib/python3.12/site-packages/pulpcore`
- Capsule pulpcore files under `/usr/lib/python3.12/site-packages/pulpcore`

If a proxy-routed test was previously applied, also back up and then remove:

- `/usr/share/gems/gems/smart_proxy_pulpcore_replicate-*`
- `/usr/share/gems/specifications/smart_proxy_pulpcore_replicate-*.gemspec`
- `/usr/share/foreman-proxy/bundler.d/pulpcore_replicate.rb`
- `/etc/foreman-proxy/settings.d/pulpcore_replicate.yml`

## Katello Files To Patch On Satellite

Copy these files from the direct-upstream Katello worktree into the matching installed paths under `/usr/share/gems/gems/katello-5.1.0.pre.master`:

- `app/controllers/katello/api/v2/capsule_content_controller.rb`
- `app/lib/actions/helpers/smart_proxy_sync_history_helper.rb`
- `app/lib/actions/katello/capsule_content/sync_capsule.rb`
- `app/lib/actions/middleware/record_smart_proxy_sync_history.rb`
- `app/lib/actions/pulp3/capsule_content/generate_metadata.rb`
- `app/lib/actions/pulp3/capsule_content/refresh_all_distributions.rb`
- `app/lib/actions/pulp3/capsule_content/refresh_distribution.rb`
- `app/lib/actions/pulp3/capsule_content/replicate.rb`
- `app/models/katello/smart_proxy_sync_history.rb`
- `app/services/katello/pulp3/api/upstream_pulp.rb`
- `app/services/katello/pulp3/distribution_conflict.rb`
- `app/services/katello/pulp3/distribution_labels.rb`
- `app/services/katello/pulp3/replication.rb`
- `app/services/katello/pulp3/replication/capability.rb`
- `app/services/katello/pulp3/replication/classification.rb`
- `app/services/katello/pulp3/replication/remote_settings.rb`
- `app/services/katello/pulp3/repository.rb`
- `lib/katello/plugin.rb`
- `lib/katello/tasks/adopt_capsule_replication.rake`

## pulpcore Files To Patch On Satellite And Capsules

Copy these files from `pulpcore-direct-upstream` into the matching installed paths under `/usr/lib/python3.12/site-packages/pulpcore`:

- `pulpcore/app/apps.py`
- `pulpcore/app/models/fields.py`
- `pulpcore/app/models/replica.py`
- `pulpcore/app/replica.py`
- `pulpcore/app/serializers/replica.py`
- `pulpcore/app/tasks/replica.py`
- `pulpcore/app/viewsets/replica.py`
- `pulpcore/app/migrations/0146_repository_retain_checkpoints.py`
- `pulpcore/app/migrations/0147_content_pulp_labels_gin.py`
- `pulpcore/app/migrations/0148_artifact_artifact_domain_size_index.py`
- `pulpcore/app/migrations/0149_distributedpublication.py`
- `pulpcore/app/migrations/0150_taskschedule_task_kwargs.py`
- `pulpcore/app/migrations/0151_upstreampulp_connect_timeout_and_more.py`
- `pulpcore/app/migrations/0152_alter_repositoryversion_content_ids.py`
- `pulpcore/app/migrations/0153_taskschedule_pulp_domain_alter_taskschedule_name_and_more.py`
- `pulpcore/app/migrations/0154_task_api_version.py`
- `pulpcore/app/migrations/0155_create_rel_path_domains.py`
- `pulpcore/app/migrations/0156_alter_contentartifact_relative_path_and_more.py`
- `pulpcore/app/migrations/0157_upstreampulp_remote_policy.py`
- `pulpcore/app/migrations/0158_upstreampulp_remote_transport_settings.py`
- `pulpcore/app/migrations/0159_upstreampulp_rate_limit.py`

RPM-specific findings from the live try:

1. The stock RPM did not stop at `0156`; it stopped at `0145`. To run the direct-upstream schema successfully, the RPM deployment needed the whole upstream migration chain from `0146` through `0159`.
2. `0156_alter_contentartifact_relative_path_and_more.py` depends on `RelativePathField`, so `pulpcore/app/models/fields.py` must be patched before migrations.
3. On the validated RPM deployment's PostgreSQL version, the `0156` migration's covering SP-GiST index is not supported. Before running migrations, edit the copied `0156` and remove the `include=('pulp_domain',)` part from the `SpGistIndex(...)` definition.
4. On this RPM baseline, the copied `0154_task_api_version.py` schema leaves `core_task.pulp_api_version` as `NOT NULL`, but the packaged runtime code still omits that field and the column had no DB-level default. The safe live fix that unblocked normal repository sync was:
   - `ALTER TABLE core_task ALTER COLUMN pulp_api_version SET DEFAULT 'v3';`
   - backfill any unexpected null rows to `'v3'` before retrying syncs
5. Do **not** partially overlay newer `pulpcore/tasking/tasks.py` or related 3.117-era runtime files onto this older RPM package set unless you also carry the matching model/exception/runtime dependencies. The reliable repair on this baseline was the DB default above, not a narrow source overlay.

## Suggested Patch Order

1. Stage the exact Katello and pulpcore source trees on the Satellite host.
2. Copy the Katello files into the installed Katello gem path on the Satellite host.
3. Normalize ownership and SELinux labels on the copied Katello files:
   - `chown root:root` on the patched files
   - `restorecon -Rv` on the touched Katello paths
4. Copy the pulpcore files into the installed pulpcore path on the Satellite host.
5. Copy the pulpcore files into the installed pulpcore path on each Capsule.
6. If the RPM deployment is on PostgreSQL older than 14, edit copied `0156_alter_contentartifact_relative_path_and_more.py` and remove `include=('pulp_domain',)` from the `SpGistIndex`.
7. On Satellite and Capsules, set the DB-level default for `core_task.pulp_api_version` to `'v3'` if the live column is `NOT NULL` without a default.
8. Remove any leftover proxy-routed Foreman Proxy plugin files if they exist.

## Restart Order

1. Run pulpcore migrations as the packaged service user, not as `root`:
   - `env DJANGO_SETTINGS_MODULE=pulpcore.app.settings PULP_SETTINGS=/etc/pulp/settings.py runuser -u pulp -- /usr/bin/pulpcore-manager migrate --noinput`
2. Restart Satellite pulpcore:
   - `systemctl restart pulpcore-api.service pulpcore-content.service pulpcore-worker@*.service`
3. Restart Satellite Foreman app tier.
   - Use the packaged app/service restart for the host
   - if you need a Rails check afterward, use `RAILS_ENV=production`
4. Run the same pulpcore migration command on each Capsule.
5. Restart each Capsule pulpcore:
   - `systemctl restart pulpcore-api.service pulpcore-content.service pulpcore-worker@*.service`
6. Restart `foreman-proxy.service` only if you removed stale proxy-routed plugin files

## Validation

Validate in this order:

1. On Satellite and each Capsule, `/pulp/api/v3/status/` reports `core >= 3.113.0`
2. On Satellite, the target Capsule SmartProxy record that already carries `Pulpcore` returns `Katello::Pulp3::Replication.capable? == true`
3. On Satellite, the live Katello code resolves:
   - `Actions::Pulp3::CapsuleContent::Replicate`
   - `Katello::Pulp3::Api::UpstreamPulp`
   - and does **not** depend on `ProxyAPI::PulpcoreReplicate`
4. `Setting[:pulp_replicate_capsule_sync] = true`
5. Only after those pass, run the first functional RPM-side sync test
6. Container repositories are expected to continue using the classic path until
   registry auth work is designed and landed

Live validation result after the DB default repair:

- `hammer repository synchronize --id 4` succeeded
- `hammer product synchronize --name "Red Hat Enterprise Linux for x86_64" --organization "Default Organization"` succeeded

For Rails-side checks on an RPM deployment, use:

- `/usr/share/foreman/bin/rails runner` with `RAILS_ENV=production`

## First Functional RPM Test

Do not start with a full sync if the RPM deployment is still pristine.

Prefer this order:

1. ensure the Capsule has an attached lifecycle environment with real content
2. verify non-zero `repositories_available_to_capsule`
3. verify at least one replicate-eligible repo
4. run a targeted sync first
5. only then consider the one-time adopt task

## One-Time Adoption

After the direct-upstream code is live and `capable?` is true, the one-time task is:

```bash
SMART_PROXY_ID=<capsule_id> ORGANIZATION_ID=<org_id> foreman-rake katello:adopt_capsule_replication
```

Only run it when the capsule actually has assigned content to adopt.

## Exit Criteria

An RPM deployment is ready for testing when all of these are true:

- the direct-upstream Katello files are installed on Satellite
- the direct-upstream pulpcore files are installed on Satellite and Capsules
- `foreman-proxy` is free of proxy-routed replicate plugin leftovers
- Pulp status reports a sufficient version everywhere
- the target Capsule SmartProxy records with `Pulpcore` are `capable? == true`
- a capsule has non-zero assigned content to sync
