# Changelog — maestra.infra

The collection is consumed from git at `version: main` (see README), so the
version in `galaxy.yml` is not what pins a consumer — the branch is. This file
exists because a collection without a changelog is a `galaxy[no-changelog]`
finding, and because the `os_update` contract is shared across four repos:
anything that changes a variable name or a hook expectation has to be findable
from one place.

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
