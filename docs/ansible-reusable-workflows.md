# Ansible workflow consolidation — central reusable workflows

Goal: kill the copy-paste of `ansible-run.yml` / `ansible-pr.yml` / `ansible-manual.yml` /
`deploy.yml` across 7 repos by hosting **reusable workflows** in `maestra-io/github-actions`
(which today holds only composite actions). Each consumer keeps a thin caller (~15-30 lines) that
passes only its own constants (playbook, env matrix, mitogen flag, vault map).

Central files (in `maestra-io/github-actions/.github/workflows/`):

| file | kind | role |
| --- | --- | --- |
| `ansible-run.yml` | `workflow_call` | the generic runner (setup → teleport → mitogen → vault → execute → artifact) |
| `ansible-pr.yml` | `workflow_call` | lint + check-mode matrix (fans out to `ansible-run.yml`) + **one** unified PR commenter |
| `ansible-manual.yml` | `workflow_call` | single manual apply/check leg with the omega-only gate rule |
| `ansible-deploy.yml` | `workflow_call` | single on-merge **apply** leg with the omega-only gate rule |

The bespoke terraform↔ansible **ordering** (detect-changes, `terraform-run.yml`,
`teleport-register-run.yml`, strict `needs`/`if` chains) stays in each repo's `deploy.yml`;
only the ansible bodies are deduplicated. This keeps the cross-tool `needs` graph where it belongs.

---

## `ansible-run.yml` input contract

**Path convention**: the Execute step runs with `working-directory: <working_directory>`
(default `ansible/`), so **`playbook` and `inventory` are `working_directory`-relative** —
`playbooks/nat-gateway.yml`, `inventory/teleport_inventory.py`, `inventory/hosts.yml`.
Never prefix them with `ansible/`. Only `requirements_pip` / `requirements_galaxy` /
`requirements_lint` are workspace-root-relative (they're consumed before the cd).

| input | type | required | default | purpose |
| --- | --- | --- | --- | --- |
| `playbook` | string | yes | — | playbook path relative to `working_directory`, e.g. `playbooks/nat-gateway.yml` |
| `inventory` | string | no | `inventory/teleport_inventory.py` | relative to `working_directory`; dynamic teleport script OR static `hosts.yml` |
| `working_directory` | string | no | `ansible` | dir holding `ansible.cfg` |
| `region` / `environment` / `site` | string | yes | — | 3-axis targeting triple |
| `inventory_group_suffix` | string | no | `""` | appended to `<region>_<env>_<site>` to build the `--limit` group (`_nat_gateway`, `_vpn`, `_sql`, `_dc`, `_haproxy_public`, …) |
| `host_limit` | string | no | `""` | explicit `--limit` override (wins over the computed group) |
| `tags` | string | no | `""` | ansible `--tags` |
| `verbosity` | string | no | `normal` | `normal` / `-v` / `-vv` / `-vvv` |
| `check_mode` | boolean | no | `false` | `--check --diff` |
| `use_mitogen` | boolean | no | `true` | Linux Mitogen linear strategy + runtime plugin-path step |
| `windows_mode` | boolean | no | `false` | forces `linear` + `ANSIBLE_HOST_KEY_CHECKING=False` for PowerShell-over-SSH |
| `vault_mode` | string | no | `none` | `none` / `public` / `tunnel` |
| `vault_addr` | string | no | `https://vault.maestra.io` | public → vault.maestra.io; tunnel → `http://127.0.0.1:8200` |
| `teleport_app` | string | no | `""` | tbot app-tunnel name (tunnel mode, e.g. `vault-omicron`); empty → no tunnel |
| `vault_role` | string | no | `""` | Vault JWT role (`jwt-github`) |
| `vault_secrets` | string (multiline) | no | `""` | passed **verbatim** to `hashicorp/vault-action` `secrets:` — the whole per-repo secret map |
| `mint_proxmox_token` | boolean | no | `false` | proxmox-only pveum token mint + cleanup (input-gated) |
| `extra_env` | string (multiline) | no | `""` | extra `KEY=VALUE` lines injected into the Execute env |
| `aws_workload_identity` | string | no | `""` | `name=<workload-identity> role_arn=<arn>` — mints a Teleport workload-identity JWT **on the runner** and exports `AWS_WEB_IDENTITY_TOKEN_FILE` / `AWS_ROLE_ARN` into the Execute env, so a play calls AWS as the CI principal instead of every target host needing its own AWS identity. Empty skips the step. Fails the job if no JWT is produced. |
| `extra_run_args` | string | no | `""` | extra `ansible-playbook` args (e.g. `-e vault_consul_template_token=…`) |
| `gh_environment` | string | no | `""` | GitHub Environment approval gate; empty → ungated |
| `artifact_name` | string | no | derived | plan/apply log artifact name (`ansible-check-<r>-<e>-<s><suffix>`) |
| `teleport_join_token` | string | no | `github-actions-infra-deploy` | teleport join token |
| `teleport_fqdn` | string | no | `teleport.maestra.io:443` | proxy (note: explicit :443) |
| `python_version` | string | no | `3.14` | uv-installed python |
| `requirements_pip` | string | no | `ansible/requirements-pip.txt` | run-time pip manifest |
| `requirements_galaxy` | string | no | `ansible/requirements.yml` | galaxy manifest |
| `no_hosts_fail_on_apply` | boolean | no | `false` | mssql/ad: empty group → fail on apply, skip on check |

Optional passthrough **secrets** (declared `required:false`, harmlessly empty elsewhere):
`VECTOR_SIEM_BASIC_AUTH_USER`, `VECTOR_SIEM_BASIC_AUTH_PASSWORD`, `PROXMOX_MONITORING_PASSWORD`
— callers use `secrets: inherit`.

Preserved behaviors (every consumer relies on ≥1): dynamic Teleport version discovery
(`/webapi/find` → `auto_update.tools_version // server_version`) + version-keyed binary cache,
galaxy collections cache, no-hosts graceful-skip sentinel (`No hosts matched`), flat
`logs/plan|apply-<region>-<env>-<site><suffix>.log` capture (the `inventory_group_suffix` is part
of the log filename AND the default artifact name, so multi-role repos like haproxy get one
distinct row/artifact per role), check-mode display trim
(`ANSIBLE_DISPLAY_OK_HOSTS=false` + `ANSIBLE_DISPLAY_SKIPPED_HOSTS=false`, check-mode only),
`upload-artifact`, `GITHUB_STEP_SUMMARY` table, per-region-env-site-suffix `concurrency`
(`cancel-in-progress:false`).

### PR commenter — standardized on ONE flavor

Both variants existed in the wild:
- **flat `plan-*.log` + `merge-multiple:true`** — nat-gateway, vpn, mssql, ad, haproxy.
- per-dir `readLog` + `merge-multiple:false` — proxmox, hyperv.

The central `ansible-pr.yml` standardizes on the **flat `plan-*.log` + `merge-multiple:true`**
flavor (`github-script@v9`, marker `<!-- ansible-plan-diff -->`, status table + gated
`<details>` per changed/failed env, truncation via the `comment_max_chars` input, default
`4000` chars per env section). proxmox + hyperv converge to it;
no behavioral loss since both read the same `changed=/failed=/unreachable=` PLAY RECAP counters
and the `No hosts matched` sentinel. Their callers just drop the old commenter.
Row labels are derived from the log filename (`plan-<r>-<e>-<s><suffix>.log` → strip `plan-`
prefix + `.log` extension), so per-row `inventory_group_suffix` values (haproxy roles) each
produce their own table row.

---

## Per-repo caller mapping (all 7)

Every caller is `uses: maestra-io/github-actions/.github/workflows/<x>.yml@<sha>` + `secrets: inherit`.

### 1. maestra-nat-gateway (PILOT) — vault none, mitogen, 3-dim
- **ansible-run.yml**: repo-local shim → central `ansible-run.yml`, pins
  `playbook=playbooks/nat-gateway.yml`, `inventory_group_suffix=_nat_gateway`,
  `use_mitogen=true`, `vault_mode=none`; inventory NOT passed (central default
  `inventory/teleport_inventory.py` matches the repo layout).
- **ansible-pr.yml**: central `ansible-pr.yml`, `envs=[us/omicron/lw, us/omega/lw,
  eu/omega/lw{tags:netplan,frr}]` (eu group may be empty → no-hosts skip).
- **ansible-manual.yml**: workflow_dispatch → local shim; omega-only gate.
- **deploy.yml**: keeps `detect-changes` + `terraform-run.yml` interleave
  (tf-omicron → ansible-omicron → tf-omega gate → ansible-omega gate); ansible legs call the
  local shim with explicit `no_hosts_fail_on_apply=true`; **eu-omega has no auto-apply leg**.

### 2. proxmox — vault public + **pveum token** (divergence class 1), mitogen
- ansible-pr/manual/deploy call central reusables with `use_mitogen=true`,
  `vault_mode=public`, `vault_role=proxmox-github-ci`,
  `vault_secrets` = the OIDC pair from `infrastructure/data/proxmox/<region>-<env>/oidc`,
  `mint_proxmox_token=true`, `extra_env`/secrets for
  `VECTOR_SIEM_*` + `PROXMOX_MONITORING_PASSWORD`, **`inventory_group_suffix=''`** —
  proxmox's limit group is the bare `<region>_<env>_<site>` triple (no `_proxmox` suffix
  exists in its inventory).
- deploy legs: us-omicron staging → (us-omega commented out) + eu-omega-lw, both need omicron.

### 3. hyperv-maestra — vault none, **windows/no-mitogen**
- `use_mitogen=false`, `windows_mode=true`, `vault_mode=none`,
  `playbook=playbooks/hyperv.yml`. Only `us-omicron-lw` live (omega commented).
- Fixes the inventory divergence at migration time (commit the teleport script OR point
  `inventory` at the static `hosts.yml`).

### 4. vpn-maestra — vault public, **5 conditional secret blocks**, mitogen, 3-dim (`_vpn`)
- The 5 per-env `if:`-gated vault blocks collapse into ONE `vault_secrets` string that the
  **caller computes per matrix row** (each env passes only the paths that exist for it).
  Each row's `vault_secrets` map must include **ALL secrets the old per-env block fetched —
  hub PSKs included** — reproducing the original env conditions 1:1. `vault-action` runs with
  `exportEnv:true`, so every fetched secret lands in `GITHUB_ENV` and the playbook may consume
  it via `lookup('env', ...)` even when no workflow line references it; dropping the hub-PSK
  fetches would be an unproven-dead-code change and is NOT part of this migration.
- `vault_role=vpn-maestra-github-ci`, suffix `_vpn`. PR matrix = the hand-listed 4 combos
  (eu/omega/aws, us/omicron/lw, eu/omega/lw, us/omega/lw). deploy stays omicron-only /
  POC-gated in the repo's own `deploy.yml`.

### 5. mssql-maestra — **dual vault (tunnel/public)** (divergence class 3), windows, static inv
- `use_mitogen=false`, `windows_mode=true`, `inventory=inventory/hosts.yml`, suffix `_sql`,
  `no_hosts_fail_on_apply=true`, `playbook=playbooks/mssql.yml`.
- The **caller computes vault routing per env**:
  - omicron → `vault_mode=tunnel`, `vault_addr=http://127.0.0.1:8200`,
    `teleport_app=vault-omicron`, `vault_role=mssql-maestra-deploy-github-ci`.
  - omega → `vault_mode=public`, `vault_addr=https://vault.maestra.io`, `teleport_app=""`,
    `vault_role=mssql-maestra-github-ci`.
- 11-key AD/SQL `vault_secrets` map + `extra_env: OP_CONNECT_HOST=https://onepassword-connect.mindbox.cloud`.
- `teleport-register-run.yml` pre-stage stays in the repo `deploy.yml`.

### 6. active-directory-maestra — **dual vault (tunnel/public)**, windows, `_dc`
- Same dual-routing pattern as mssql (roles `active-directory-maestra-deploy-github-ci`
  omicron / `active-directory-maestra-github-ci` omega), `use_mitogen=false`,
  `windows_mode=true`, suffix `_dc`, `playbook=playbooks/ad-dns-dhcp.yml`,
  10-key `vault_secrets` from `infrastructure/active-directory/{domain-join,domain,mssql}`.
- deploy.yml keeps asymmetric teleport-register gating (omega `==success`, omicron `!=failure`).

### 7. haproxy-maestra — vault public + **consul-template token** (divergence class 2), mitogen, role-dim
- `use_mitogen=true`, `vault_mode=public`, `vault_role=haproxy-maestra-github-ci`,
  `playbook=playbooks/haproxy.yml`. The `role` input (`haproxy_public|private|api|cdp`)
  becomes `inventory_group_suffix=_${role}`.
- **consul-template token**: CDP+apply+`contains(tags,'consul-template')` only. The caller
  passes `vault_secrets` = `github/data/common/VAULT_CONSUL_TEMPLATE_TOKEN_AZURE_PRODUCTION field
  | CONSUL_TEMPLATE_VAULT_TOKEN` **and** `extra_run_args: -e vault_consul_template_token=…`
  ONLY for the CDP row (other rows pass empty). `cdp-deploy.yml` stays a separate
  dispatch-only canary caller.
- `GH_TOKEN` for the `gh release download` of the haproxy-otel `.deb` is provided via
  `extra_env: GH_TOKEN=${{ github.token }}` (or a job-level env in the caller).

---

## How the 3 divergence classes are handled

1. **proxmox `pveum` API-token mint** — NOT a Vault fetch (it's `tsh ssh` + `pveum user/acl/token`
   producing `PROXMOX_API_TOKEN_SECRET`, consumed **in the same job** by Execute; env can't cross
   reusable boundaries). Handled as an **input-gated optional step** (`mint_proxmox_token: true`)
   inside `ansible-run.yml` + its `always()` cleanup step. Inert (`if:` false) for the other 6
   repos. Chosen over a divergent `ansible-run-proxmox.yml` fork so there's ONE runner; the step
   is cleanly scoped by the boolean and touches nothing when off.

2. **haproxy consul-template token** — this one IS a Vault fetch, so it needs **no special step**:
   the caller puts the single KV line in `vault_secrets` and threads the value into the run via
   `extra_run_args: -e vault_consul_template_token=…`, both supplied only for the CDP matrix row
   (role-conditional + tags-conditional + apply-only gating lives in the caller's matrix, not the
   generic workflow).

3. **mssql / ad Vault-tunnel mode** — folded into `ansible-run.yml` via `vault_mode=tunnel` +
   `teleport_app` + `vault_addr`. A `Start Vault tunnel` step (tbot v2 application-tunnel →
   `127.0.0.1:8200`, gated `if: vault_mode=='tunnel' && teleport_app != ''`) and an `always()`
   `Stop Vault tunnel` step wrap the generic `vault-action` fetch. Because the mode is a per-call
   **input**, the dual omega-public/omicron-tunnel behavior inside ONE repo is expressed by the
   **caller computing the routing per matrix row** — no second workflow, no divergent copy. (A
   scoped `ansible-run-tunneled.yml` was considered and rejected: the tunnel is 2 guarded steps,
   not enough surface to justify a fork, and a fork couldn't express the per-env dual mode without
   the caller branching anyway.)

---

## Caller wiring checklist (sharp edges — verify per consumer before merge)

- **AD dual-vault per-row wiring** (active-directory-maestra): each matrix row / deploy leg
  carries its OWN vault routing —
  omicron: `vault_mode=tunnel`, `teleport_app=vault-omicron`, `vault_addr=http://127.0.0.1:8200`,
  `vault_role=active-directory-maestra-deploy-github-ci`;
  omega: `vault_mode=public`, `vault_addr=https://vault.maestra.io`, `teleport_app=''`,
  `vault_role=active-directory-maestra-github-ci`. Never share one vault block across rows.
- **`no_hosts_fail_on_apply=true` is REQUIRED on every mssql/AD apply leg** (deploy + manual
  apply). Their empty-group condition is an error on apply (host lost from static inventory),
  only a skip on check.
- **haproxy consul-template fetch is caller-gated to non-check CDP runs only**: the CDP apply
  row passes `vault_secrets` = the `VAULT_CONSUL_TEMPLATE_TOKEN_AZURE_PRODUCTION | CONSUL_TEMPLATE_VAULT_TOKEN`
  line AND `extra_run_args` = the **literal string**
  `-e vault_consul_template_token=$CONSUL_TEMPLATE_VAULT_TOKEN`
  (single-quoted in YAML; the runner's Execute shell expands it AFTER vault-action exported the
  env var — do NOT try to interpolate it in workflow expressions). Check-mode CDP rows and all
  non-CDP rows pass **empty `vault_secrets`** (and no extra_run_args).
- **hyperv**: set `requirements_galaxy` to its real manifest path (or commit one — the repo has
  none today), and resolve its inventory divergence BEFORE migrating: the teleport dynamic
  inventory script is **not committed** in hyperv-maestra, so either commit it or pass
  `inventory=inventory/hosts.yml` (static).
- **`lint_paths` override** for repos without `roles/`: the default is `.`
  (working_directory-relative); repos whose ansible tree would make `.` too noisy can pass
  e.g. `lint_paths=playbooks/` — both yamllint and ansible-lint run from `working_directory`,
  so the same relative paths feed both tools.
- **proxmox** passes `inventory_group_suffix=''` (bare triple limit group, see above).
- **vpn** reproduces ALL original per-env vault fetches incl. hub PSKs (see above).

## Action pinning — SHA pinning is the decided policy

- Third-party actions inside the central workflows are currently written as
  `owner/action@vX` tags with a `# TODO: SHA-pin via Renovate on landing` comment. **On landing
  in `maestra-io/github-actions` they MUST be converted to full-SHA pins** (`owner/action@<sha>
  # vX.Y.Z`); Renovate's `github-actions` manager then keeps the SHAs bumped. Tag-pinned
  consumers (proxmox/hyperv/mssql/ad/haproxy) inherit the central SHA pins for free once
  migrated.
- Callers **SHA-pin the central ref**:
  `uses: maestra-io/github-actions/.github/workflows/<x>.yml@<full-sha> # renovate: maestra-io/github-actions`
  (the `@0000…0000` placeholders in the nat-gateway drafts). Renovate's `github-actions`
  manager natively bumps SHA-pinned `uses:` refs of reusable workflows; the `# renovate:`
  comment keeps the mapping explicit. SHA pinning (not tag pinning) of the central ref is the
  decided policy — a moving tag on the workflow that holds Teleport/Vault auth would be a
  supply-chain hole.

## Backward-compatibility checklist (per consumer, before merge)

- [ ] inventory: teleport script committed (hyperv) or `inventory` input points at the real path.
- [ ] `requirements_pip` vs `requirements_lint` filenames match the repo (both are inputs).
- [ ] windows repos set `use_mitogen=false` + `windows_mode=true`.
- [ ] dual-vault repos compute `vault_mode`/`vault_addr`/`teleport_app`/`vault_role` per matrix row.
- [ ] `no_hosts_fail_on_apply=true` only for mssql/ad (asymmetric exit).
- [ ] omega-only gate preserved (`gh_environment` derivation), omicron ungated.
- [ ] `deploy.yml` terraform/teleport-register ordering + POC `if:` gates left untouched in-repo.
- [ ] PR commenter converged to the flat flavor (proxmox/hyperv drop the per-dir readLog).
# Patch for ~/work/github-actions/docs/ansible-reusable-workflows.md
# Append the following section at the end of the file:

---

## Status

**Ansible phase: DONE.** All 7 consumer repos migrated and merged as of
2026-07-02; central family released as **v1.0.5** (`ansible-run.yml`,
`ansible-pr.yml`, `ansible-manual.yml`, `ansible-deploy.yml`).

The **Terraform workflow family** (`terraform-run.yml`, `terraform-pr.yml`,
`terraform-manual.yml`) follows the same pattern — repo-local shim keeps the
existing caller surface, deploy orchestration stays repo-local, per-repo
deltas become inputs. Its input contract and per-repo migration mapping live
in [docs/terraform-reusable-workflows.md](terraform-reusable-workflows.md).
Key differences from the ansible family: per-run Proxmox pveum tokens
(`<prefix>-<run_id>-<attempt>`), an ordering contract ending with the Proxmox
API tunnel as the last `tsh ssh`, and `gh_environment` always passed verbatim
by the caller (never derived centrally — GitHub Environment naming differs
per repo: dashes vs underscores).
