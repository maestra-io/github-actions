# Rolling OS update — the shared workflow and the per-repo contract

`issues-maestra#1104`. Patches the pet VMs (haproxy farms, NAT gateways, VPN hosts):
`apt dist-upgrade` + kernel + reboot, **one host at a time**, each host **drained out
of rotation first** and **proven healthy** before the next one is touched.

Kubernetes nodes are not in scope — Deckhouse patches those.

## Shape

| piece | where | what it knows |
|---|---|---|
| `ansible-os-update.yml` | this repo, `.github/workflows/` | sequencing: enumerate → plan → per-host `apply` matrix (`max-parallel: 1`, `fail-fast`) |
| `maestra.infra.os_update` role | this repo, `ansible/collections/maestra/infra/` | the generic half: plan, silences, holds, apt, reboot, kernel GC, drain marker |
| `ansible/tasks/os-update/*.yml` | **each consumer repo** | the role-specific half: what "in rotation" means for haproxy vs nat-gw vs vpn |

The consumer repo installs the role as a Galaxy collection from this repo (public, so no
CI auth is involved — same as the other public roles already in `requirements.yml`):

```yaml
collections:
  - name: https://github.com/maestra-io/github-actions.git#/ansible/collections/maestra/infra/
    type: git
    version: main
```

`version: main` means the tip of this repo, re-installed by every job: a role change
merged mid-sweep is picked up by the next host's job, so the hosts of one sweep can run
different role code.

## Why GitHub Actions owns the host sequencing

`teleport-actions/auth` mints **one SSH certificate per job**, at job start. A 12-host
farm at ~14 min/host is ~2.5 h, so a single-job `serial: 1` run dies with
`ssh: cert has expired` on every remaining host at once. haproxy-maestra already carries
that scar (`deploy.yml`: *"rolling_interval=180s stretches the apply past the Teleport SSH
session lifetime — run 25733140071 lost the API tunnel ~16 minutes into [2/4]"*).

One job per host ⇒ a fresh certificate per host, **"Re-run failed jobs" is the resume
button** (it replays the failed host and everything `fail-fast` cancelled, in order), and
omega gets a per-host approval gate for free.

The per-host jobs keep ansible-run's **farm-level** concurrency group, so an os-update can
never interleave with a config deploy of the same farm — a deploy landing mid-drain would
cheerfully unmask the `keepalived`/`haproxy` unit we just masked.

## The three invariants

1. **A drain must survive the reboot.** Otherwise the reboot *is* the undrain: the host
   comes up serving while `verify` is still polling. Runtime-only state (`disable frontend`
   on the haproxy admin socket, `bgp graceful-shutdown` in the running config) does **not**
   qualify. Mask the unit, or drain in a plane that persists.
2. **A drain is proven from the consumer's side.** Not "we applied the config" — but *the
   NAT gateway now has one nexthop and it isn't us*, *Route53 no longer answers with our IP*,
   *established sessions on this host fell to zero*.
3. **Every gate fails closed.** An empty probe result is a failure, not a pass. Every
   read-only probe carries `check_mode: false`, because `command`/`shell`/`apt` are *skipped*
   under `--check`, leaving registers undefined and asserts vacuously green. The dry run is
   `mode: plan`, never `--check`.

## The contract each consumer repo implements

`ansible/tasks/os-update/`:

| file | runs | must | must not |
|---|---|---|---|
| `vars.yml` | always | set `os_update_peers`, `os_update_farm`, `os_update_pinned_extra`, `os_update_silence_sets` | mutate anything |
| `preflight.yml` | always, immediately before the drain | assert **every peer** healthy with a live probe (`delegate_to`), and this host safe to reboot | `ignore_errors`, `failed_when: false`, warn-and-continue |
| `drain.yml` | apply | write the drain marker **first** (include the role's `marker.yml` with `os_update_marker_action: write`, before any mutation), then take the host out of rotation **persistently**, then **prove it from the consumer side** | prove it by "the command succeeded"; `sleep` instead of poll |
| `verify.yml` | apply, after reboot, **before** undrain | prove the host is healthy again, with `until`/`retries` | undrain; touch the peer |
| `undrain.yml` | **`always`** | put it back, idempotently, safe on a host that was never drained | fail silently |
| `settle.yml` | apply, after undrain | prove traffic is actually flowing and the pair is redundant again | be a `sleep` |

`os_update_silence_sets` is a **list of lists**: each element becomes its **own** silence.
Matchers *within* one silence are ANDed — folding `instance=<host>` and
`alertname=BgpPeerDown` and `node_group=<peer's group>` into a single silence yields a
silence that matches nothing, and the alerts that most need suppressing are the ones firing
on the **surviving peer** and on the **far end**, whose `instance` is not ours.

## Update payload

`apt-get dist-upgrade`, with **dpkg holds** on the IaC-owned packages: `teleport` (its
postinst restarts the very agent we are connected through), `frr`, `consul`, plus whatever
the consumer adds (`haproxy`, `haproxy-otel` — custom builds, not from the archive).

A hold is not enough on its own: apt may satisfy a dependency by **removing** a held
package, and `Remv haproxy-otel` un-diverts `/usr/sbin/haproxy` and the LB never comes back.
So after the holds are applied the upgrade is re-simulated and a **tripwire** asserts that no
pinned package appears as `Inst`, `Remv` **or** `Purg`.

Reboot is decided by three independent signals: `/var/run/reboot-required`, *newest installed
kernel ≠ running kernel* (a host can need a reboot with zero pending packages), and *the
upgrade installs a `linux-image-*`*.

Before any reboot the role sets `GRUB_RECORDFAIL_TIMEOUT` — without it, a headless VM that
fails to boot once waits **forever** in the GRUB menu (`GRUB_TIMEOUT=0` +
`GRUB_TIMEOUT_STYLE=hidden` and no recordfail timeout is the current state of these boxes),
turning a recoverable failed reboot into a Proxmox-console rescue.

## When a run dies mid-drain

A cancelled runner never executes `always`. Three layers, of which only the first is a gate:

1. **The Alertmanager silence is the interlock.** It lives off-box and carries a dead-man
   `endsAt`. `guards.yml` refuses to start if another host in the contour holds an open
   os-update silence. (The on-host metric is *not* usable as the interlock: it disappears
   during the reboot, so `count(...) == 0` evaluates over an empty vector and fails **open**
   in exactly the window it exists for.)
2. **The on-disk marker** `/var/lib/os-update/drained.json` — a re-run reads it, knows the
   host is already drained, and finishes the job idempotently.
3. **`OsUpdateHostStrandedDrain`** fires on the marker's metric outliving the silence
   (`silence_minutes` < the alert's `for:` — asserted in code, so the safety net can never be
   silenced by the run that stranded the host).

Escape hatch: `mode: undrain-only` (optionally `host_limit: <host>`). It skips preflight on
purpose — the peer gates there are exactly what fails in the scenario the hatch exists for.

## Running it

Each consumer repo has its own `os-update.yml` shim; targeting is per-repo (the nat-gw
shim is hard-wired to `_nat_gateway`, haproxy picks the farm via `farm`, vpn picks
spokes/hubs via `target`):

```bash
# read-only, whole farm: pending packages, reboot decision, peer health, /boot headroom
gh workflow run os-update.yml --repo maestra-io/maestra-nat-gateway \
  -f environment=omicron -f mode=plan

# one host, for real
gh workflow run os-update.yml --repo maestra-io/maestra-nat-gateway \
  -f environment=omicron -f mode=apply -f host_limit=us-omicron-lw-nat-gw-02

# the whole farm, one host at a time, stopping at the first failure
gh workflow run os-update.yml --repo maestra-io/maestra-nat-gateway \
  -f environment=omicron -f mode=apply

# haproxy: same shape, plus the farm
gh workflow run os-update.yml --repo maestra-io/haproxy-maestra \
  -f environment=omicron -f farm=cdp -f mode=plan

# vpn: same shape, plus spokes|hubs
gh workflow run os-update.yml --repo maestra-io/vpn-maestra \
  -f environment=omicron -f target=spokes -f mode=plan
```

Idempotency is a derived property, not a state file: a host with an empty upgrade
simulation, no `reboot-required` and the newest kernel already running is **never drained**
and never rebooted — the job is green in ~60 s. So re-running after a partial sweep is safe
and cheap.

## Not covered by this workflow

- **`eu-omega-lw-*`** — out of scope for v1. The EU haproxy `kube-cdp` pair is owned by
  GitLab `development/ansible` (Octopus), and EU nat-gw's keepalived + AWS route-failover
  scripts are **not in IaC at all** (a full playbook run there would render `keepalived.conf`
  with no `vrrp_instance` and drop the VIPs). Separate issue.
- **CVEs in the pinned packages themselves** (teleport, frr, haproxy) — they stay. Bumping
  them is each component's own upgrade path.
- **ESM-only CVEs.** Ubuntu Pro is not attached anywhere in the org, so a set of findings
  cannot be cleared by any amount of `dist-upgrade`. That is a procurement decision, not a
  workflow feature.
