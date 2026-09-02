# Changelog — maestra.infra

The collection is consumed from git at `version: main` (see README), so the
version in `galaxy.yml` is not what pins a consumer — the branch is. This file
exists because a collection without a changelog is a `galaxy[no-changelog]`
finding, and because the `os_update` contract is shared across four repos:
anything that changes a variable name or a hook expectation has to be findable
from one place.

## 1.1.0

- `os_update` role: new `os_update_mode: binary-update`
  ([issues-maestra#1373](https://github.com/maestra-io/issues-maestra/issues/1373)).
  Drain → swap the SERVING BINARY → verify → undrain, skipping the
  apt/kernel/reboot path entirely. **Its failure contract is the inverse of
  `apply`'s: a host that fails any step STAYS DRAINED and the job goes red**, the
  drain marker is left in place, and the silences are still dropped so
  `OsUpdateHostStrandedDrain` can report it. Recovery is a re-run with the previous
  artifact pinned, or `mode: undrain-only`.
- **Two new consumer hooks, both OPTIONAL**: `ansible/tasks/os-update/binary-update.yml`
  and `ansible/tasks/os-update/verify-binary-update.yml`. A consumer that does not
  ship them is unaffected — every existing mode behaves byte-identically — and an
  attempt to run `mode: binary-update` there is refused **before anything is
  drained**, naming the missing files.
- `plan.yml` is not included in `binary-update` (its `/boot` guard would refuse a
  run that unpacks no kernel), and the reusable workflow's farm-wide `plan` job is
  skipped for the same mode. Peer gates still run: the role's `preflight` runs for
  every mode except `stage`.
- Contract:
  [docs/ansible-os-update.md](https://github.com/maestra-io/github-actions/blob/main/docs/ansible-os-update.md).

## 1.0.0

- `os_update` role: plan / stage / apply / undrain-only, Alertmanager maintenance
  silences, dpkg holds, `apt dist-upgrade`, reboot, kernel GC, drain marker.
  Contract for the consumer-side hooks:
  [docs/ansible-os-update.md](https://github.com/maestra-io/github-actions/blob/main/docs/ansible-os-update.md).
- Role variable `node_exporter_textfile_dir` renamed to
  `os_update_node_exporter_textfile_dir`. **Backward compatible**: the new
  default is `"{{ node_exporter_textfile_dir | default('/var/lib/node_exporter') }}"`,
  so every consumer that declares the fleet-wide `node_exporter_textfile_dir`
  (all of them do, in `ansible/inventory/group_vars/all.yml`) or overrides it per
  run (maestra-io/kubernetes-clusters sets `/var/run/node-exporter-textfile` in
  its `ansible/tasks/os-update/vars.yml`) keeps working unchanged.
