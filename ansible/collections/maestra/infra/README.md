# maestra.infra

Shared Ansible content for Maestra infrastructure repos.

## `os_update`

The **generic half** of the rolling OS-update workflow (`issues-maestra#1104`): plan,
Alertmanager maintenance silences, dpkg holds, `apt dist-upgrade`, reboot, kernel GC,
and the drain marker.

The **role-specific half** — what "in rotation" actually *means* for a haproxy farm vs
a NAT gateway vs a VPN host — is a task-file contract each consumer repo implements at
`ansible/tasks/os-update/{vars,preflight,drain,verify,undrain,settle}.yml`.

Full contract and rationale:
[docs/ansible-os-update.md](https://github.com/maestra-io/github-actions/blob/main/docs/ansible-os-update.md).

## Install

The repo is public, so no CI auth is involved:

```yaml
# ansible/requirements.yml
collections:
  - name: https://github.com/maestra-io/github-actions.git#/ansible/collections/maestra/infra/
    type: git
    version: main
```

```yaml
# ansible/playbooks/os-update.yml
- name: OS update
  hosts: all
  serial: 1
  any_errors_fatal: true
  strategy: linear      # NOT mitogen — it does not survive reboot/wait_for_connection
  become: true
  roles:
    - role: maestra.infra.os_update
```

Driven one host per GitHub job by
`maestra-io/github-actions/.github/workflows/ansible-os-update.yml`.
