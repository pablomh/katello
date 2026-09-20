# Capsule Replicate Direct-Upstream Handoff

This handoff is for the **direct-upstream** architecture:

- Katello -> pulpcore `UpstreamPulp` API directly
- no `pulp_smart_proxy` hop
- no `ProxyAPI::PulpcoreReplicate` dependency
- no custom `foreman-proxy` plugin/image required

Current scope note:

- direct-upstream replicate is currently intended for yum repositories
- container repositories stay on the classic sync path until Satellite's `/v2/`
  registry token flow has a deliberate Capsule-facing auth design

## Exact Source Of Truth

Build from these exact working trees:

- Katello: `/Users/pmendezh/work/Katello/katello/.claude/worktrees/capsule-replicate-direct-upstream`
- pulpcore: `/Users/pmendezh/work/pulp/pulpcore-direct-upstream`

Do **not** infer the right tree from git base commit alone.

There are sibling worktrees on the same underlying repos that sit on the same base commit but implement a different, proxy-routed design:

- not this handoff: `/Users/pmendezh/work/Katello/katello`
- not this handoff: `/Users/pmendezh/work/Katello/katello/.claude/worktrees/capsule-replicate-pulp-proxy`
- not this handoff: `/Users/pmendezh/work/pulp/pulpcore-replica-remote-credential-split`

Those paths are internally consistent as a separate Katello -> proxy -> pulpcore bundle, but they are **not** the design this session's direct-upstream work refers to.

## Containerized Deployments

For the direct-upstream design, a containerized deployment only needs two custom artifacts:

- custom `foreman`
- custom `pulp`

It should **not** depend on a custom `foreman-proxy` image or a `pulpcore_replicate` proxy feature.

Use this workflow for `foremanctl` or other Podman-managed deployments where
Foreman and Pulp are delivered as container images.

Choose a dedicated build workspace on the Satellite host, for example:

- `/root/replicate-direct-upstream-build`

## Containerized Pulp Image

Base image:

- `quay.io/foreman/pulp:foreman-nightly`

Example validated image tag:

- `localhost/pulp:replicate-direct-upstream-full-20260831` -> `6aa9dc9c7484`

Critical packaging lesson:

- the real Pulp services run under `/usr/bin/python3.12 -sP`
- that interpreter ignores `/usr/local` site-packages
- a normal `pip install` into `/usr/local` is **not** enough

Successful build shape:

1. install `python3-pip`
2. remove the packaged `pulpcore` copy from `/usr/lib/python3.12/site-packages`
3. install the direct-upstream pulpcore source into `/usr/lib/python3.12/site-packages`
4. validate with `/usr/bin/python3.12 -sP`

Required Pulp-side files from the direct-upstream source tree:

- `pulpcore/app/models/replica.py`
- `pulpcore/app/replica.py`
- `pulpcore/app/serializers/replica.py`
- `pulpcore/app/tasks/replica.py`
- `pulpcore/app/viewsets/replica.py`
- `pulpcore/app/migrations/0157_upstreampulp_remote_policy.py`
- `pulpcore/app/migrations/0158_upstreampulp_remote_transport_settings.py`
- `pulpcore/app/migrations/0159_upstreampulp_rate_limit.py`

Exact validation that matters:

- `importlib.metadata.version("pulpcore")` reports `3.117.0.dev0`
- `pulpcore.__file__` resolves under `/usr/lib/python3.12/site-packages`
- host-facing `/pulp/api/v3/status/` reports `core >= 3.113.0`

## Containerized Foreman Image

Base image:

- `quay.io/foreman/foreman:nightly`

Current rebuilt direct-upstream image tag in the validated containerized deployment:

- `localhost/foreman:replicate-direct-upstream-full-20260831` -> `b59dc4e8fe75`

Do **not** overlay the entire Katello source tree into the packaged gem path.

That breaks runtime-only images because Foreman then loads packaged tasks that assume test/support layout from a full source checkout.

Use a runtime-only overlay from the direct-upstream Katello worktree.

Runtime files to overlay from the Katello direct-upstream worktree:

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

The direct-upstream Foreman image does **not** need:

- `lib/proxy_api/pulpcore_replicate.rb`
- `lib/smart_proxy_pulpcore_replicate*`
- `db/seeds.d/104-proxy.rb`

If those files are part of a build recipe, that recipe is targeting the wrong architecture.

## Containerized Foreman Proxy State

For direct-upstream, `foreman-proxy` should stay on the stock image.

If a prior proxy-routed experiment placed:

- `/etc/containers/systemd/foreman-proxy.image.d/90-user.conf`

on Satellite or Capsules, remove it and restart `foreman-proxy.service`.

The direct-upstream design does not need a live `pulpcore_replicate` feature on the proxy.

## Containerized Image Overrides

Satellite should have:

`/etc/containers/systemd/foreman.image.d/90-user.conf`

```ini
[Image]
Image=localhost/foreman:replicate-direct-upstream-full-20260831
Policy=never
```

`/etc/containers/systemd/pulp.image.d/90-user.conf`

```ini
[Image]
Image=localhost/pulp:replicate-direct-upstream-full-20260831
Policy=never
```

Capsules should have:

`/etc/containers/systemd/pulp.image.d/90-user.conf`

```ini
[Image]
Image=localhost/pulp:replicate-direct-upstream-full-20260831
Policy=never
```

Capsules should **not** need a `foreman-proxy.image.d/90-user.conf` for this design.

## Containerized Rollout Order

1. Stage the exact direct-upstream Katello and pulpcore source trees onto the Satellite host.
2. Build the custom `pulp` image from `pulpcore-direct-upstream`.
3. Build the custom `foreman` image from `capsule-replicate-direct-upstream`.
4. Push the `pulp` image to the temporary Satellite-local registry if Capsules need to pull it.
5. Pull and retag the custom `pulp` image on all Capsules.
6. Write/update the Satellite `foreman` and `pulp` image overrides.
7. Write/update the Capsule `pulp` image overrides.
8. Remove any custom `foreman-proxy` image override left over from a proxy-routed deployment.
9. `systemctl daemon-reload`.
10. Restart Satellite `pulp`.
11. Restart Satellite `foreman`.
12. Restart Satellite `foreman-proxy` only if you removed a stale custom image override.
13. Restart Capsule `pulp`.
14. Restart Capsule `foreman-proxy` only if you removed a stale custom image override.
15. Ensure `Setting[:pulp_replicate_capsule_sync] = true`.

## Containerized Validation

For the direct-upstream design, validate these and ignore proxy-only markers:

1. On Satellite and Capsules, host-facing `/pulp/api/v3/status/` reports `core >= 3.113.0`.
2. On Satellite, `Katello::Pulp3::Replication.capable?(capsule_pulp_proxy)` is `true` for each `*-pulp` SmartProxy.
3. `Actions::Pulp3::CapsuleContent::Replicate` exists and talks through `Katello::Pulp3::Api::UpstreamPulp`, not through `ProxyAPI::PulpcoreReplicate`.
4. The setting `pulp_replicate_capsule_sync` is enabled.
5. A real Capsule sync or one-time adopt/replicate smoke test succeeds.
6. Container repositories are expected to continue using the classic path until
   registry auth work is designed and landed.

## Containerized Recovery Notes

Two environment-repair notes from the validated containerized run are worth carrying forward.

If a freshly rebuilt containerized environment fails a library repo sync with:

- `undefined method 'repository_href' for nil`

check whether the default-view library repos are missing their primary-Pulp
`RepositoryReference` rows.

On the observed rebuild, the RHEL library repos `1-6` resolved to
`Default Organization View` but had no current backend reference even though
CV-derived references existed.

Do not fabricate those rows directly in SQL.

Repair them through Katello's own repository-create path, for example via
`rails runner`, calling:

- `repo.backend_service(SmartProxy.pulp_primary).with_mirror_adapter.create(false)`

for each affected library repo.

If later CV or CCV publishes are blocked by stale paused tasks, snapshot the
blocking tasks first and then clear only the stale lock rows that still block
the current run.

After recreating the missing default-view repository references and clearing
stale publish locks, the product sync path succeeded again in the containerized
environment:

- `hammer product synchronize --name "Red Hat Enterprise Linux for x86_64" --organization "Default Organization"`

## RPM Deployment

Use in-place filesystem patching for RPM-based Satellite and Capsule hosts, not
the container image workflow above.

Observed runtime paths:

- Katello runtime gem: `/usr/share/gems/gems/katello-5.1.0.pre.master`
- Foreman app root: `/usr/share/foreman`
- pulpcore runtime: `/usr/lib/python3.12/site-packages/pulpcore`

For the direct-upstream design, RPM deployments need only:

1. Katello runtime patches on Satellite
2. pulpcore runtime patches on Satellite and Capsules

RPM deployments do **not** need a custom Foreman Proxy plugin install for this design.

If a proxy-routed test had placed `pulpcore_replicate` plugin files on RPM Capsules, remove them rather than carrying them forward.

### RPM Katello Files

Patch these on the Satellite from the direct-upstream Katello worktree:

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

### RPM pulpcore Files

Patch these on the Satellite and on every Capsule from `pulpcore-direct-upstream`:

- `pulpcore/app/models/replica.py`
- `pulpcore/app/replica.py`
- `pulpcore/app/serializers/replica.py`
- `pulpcore/app/tasks/replica.py`
- `pulpcore/app/viewsets/replica.py`
- `pulpcore/app/migrations/0157_upstreampulp_remote_policy.py`
- `pulpcore/app/migrations/0158_upstreampulp_remote_transport_settings.py`
- `pulpcore/app/migrations/0159_upstreampulp_rate_limit.py`

### RPM Restart Order

1. Patch Satellite Katello.
2. Patch Satellite pulpcore.
3. Patch Capsule pulpcore.
4. Restart Satellite pulpcore services.
5. Restart Satellite Foreman services.
6. Restart Capsule pulpcore services.
7. Restart `foreman-proxy.service` only if you removed stale proxy-routed overrides or plugin files.
8. Enable `Setting[:pulp_replicate_capsule_sync] = true`.
9. Validate `capable?` on the `*-pulp` SmartProxy records before the first real sync.

## One-Time Adoption

The direct-upstream Katello worktree includes:

- `lib/katello/tasks/adopt_capsule_replication.rake`

Use it only after:

- the direct-upstream Katello code is live
- the direct-upstream pulpcore code is live
- Capsule `*-pulp` SmartProxy records pass `capable?`

The task is:

- `SMART_PROXY_ID=<capsule_id> ORGANIZATION_ID=<org_id> foreman-rake katello:adopt_capsule_replication`

## Operator Rule

When someone says "deploy the direct-upstream build", require them to name both exact source roots:

- the Katello worktree path
- the pulpcore worktree path

Do not accept "same repo" or "same commit" as enough evidence that the selected trees belong to the same architecture.
