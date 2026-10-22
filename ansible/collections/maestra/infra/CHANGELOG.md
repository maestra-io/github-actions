# Changelog — maestra.infra

The collection is consumed from git at `version: main` (see README), so the
version in `galaxy.yml` is not what pins a consumer — the branch is. This file
exists because a collection without a changelog is a `galaxy[no-changelog]`
finding, and because the `os_update` contract is shared across four repos:
anything that changes a variable name or a hook expectation has to be findable
from one place.

## 1.3.0

- New role `wireguard_burst` ([issues-maestra#1444](https://github.com/maestra-io/issues-maestra/issues/1444)):
  WireGuard termination for Kubernetes burst nodes with one BFD-tracked FRR
  static `/32` per slot (300 ms x 3). Two modes: `embedded` (on a host that
  owns its own nftables/FRR; the role exposes the lines to include) and
  `dedicated` (owns nftables, FRR and sysctls, announces live slots to its
  uplinks over eBGP with BFD). Gateway public-key assert, per-slot textfile
  metrics. Contract: `roles/wireguard_burst/README.md`.
- `os_update`: no change.

## 1.2.2

- `os_update` role: `mode=undrain-only` posts the same post-run tail silences
  the success path does, before dropping the maintenance silences. The hatch
  runs after a cancelled or dead run, i.e. while the workloads the drain moved
  are landing back, and every alert whose `for:` elapsed under the maintenance
  silence fired the second it was dropped (us-iota node 02, 19.10.2026 19:52
  UTC: TooManyLogs x7 across three contours, AlertingRulesError,
  ReconcileErrors, ApdexLow — all noise from pods returning).
- No consumer change.

## 1.2.1

- `os_update` role: `apt.yml` sets `NEEDRESTART_SUSPEND=1`. needrestart is
  installed on Ubuntu 24.04 hosts (all three us-iota nodes) and in mode `a`
  restarted every service on an upgraded lib from inside dpkg (k0scontroller /
  etcd on all three iota nodes, 07.10.2026, from an unrelated apt run). `stage`
  runs apt on a host still in rotation, so that restart broke its "activate
  nothing" contract outright. Trade-off: an `apply` whose upgrade needs no
  reboot leaves services on the old libs until the next reboot.
- No consumer change.

## 1.2.0

- `os_update` role: **post-run tail silence** after a successful `apply`
  ([issues-maestra#1104](https://github.com/maestra-io/issues-maestra/issues/1104)).
  Once verify → undrain → marker clear → settle have all passed, the same
  `os_update_silence_sets` are re-posted with `createdBy: os-update-tail` and
  `endsAt = now + os_update_tail_silence_minutes` (default 15; `0` disables it),
  and only then are the maintenance silences expired. The tail covers alerts
  whose `for:` outlasts the job while pinned workloads come back
  (KafkaClusterImbalanced fired 64 s after a us-omicron worker job, 19.10.2026).
  A failed `apply`, `binary-update` and `undrain-only` post no tail.
- The tail's `createdBy` is outside `^gha-os-update`, so it never trips the
  contour-wide one-at-a-time guard: the next host starts while the tail is up.
- No consumer change: new role default, no new hook, no new variable to set.

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
