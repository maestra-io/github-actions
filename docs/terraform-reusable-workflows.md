# Terraform reusable workflows

Central reusable GitHub Actions workflows for the Proxmox-over-Teleport
Terraform repos: **maestra-nat-gateway, vpn-maestra, mssql-maestra
(default branch `master`), active-directory-maestra, haproxy-maestra**.
Second phase of the CI dedup program; the ansible phase (see
[ansible-reusable-workflows.md](ansible-reusable-workflows.md)) is DONE and
established the pattern: central reusable + repo-local shim with an
unchanged caller surface, deploy orchestration stays repo-local.

Files:

- `.github/workflows/terraform-run.yml` — generic runner (plan/apply)
- `.github/workflows/terraform-pr.yml` — fmt ∥ plan matrix ∥ sticky PR comment
- `.github/workflows/terraform-manual.yml` — dispatch-shaped forwarding leg

## Execution model (terraform-run)

Ordering contract (fixed, do not reorder):

1. checkout → extra_env injection → TF plugin cache → Teleport version probe
   (`/webapi/find` → `.auto_update.tools_version // .server_version`) +
   binary cache → `teleport-actions/setup@v1` + `auth@v2` (join token
   `github-actions-infra-deploy`, ttl 30m)
2. Export `TELEPORT_IDENTITY_FILE` / `TBOT_DEST_DIR` / `TELEPORT_PROXY` —
   **hidden contract**: terraform local-exec provisioners in the consumer
   repos run bare `tsh ssh` against this ambient session.
3. Vault tunnel (tbot application-tunnel, `storage: type: memory`;
   fail-fast: if 127.0.0.1:8200 isn't accepting after 15 attempts →
   `::error` + exit 1) → Vault fetch (`hashicorp/vault-action@v4` —
   prod-proven: ansible central v1.0.5 runs it green in tunnel mode on
   mssql/AD ansible PRs — jwt-github, secrets map verbatim; name your
   exports `TF_VAR_*` directly).
4. Proxmox pveum token mint — **always per-run**:
   `<proxmox_token_prefix>-<run_id>-<attempt>`, json-first parse
   (`--output-format=json | jq -er .value`) with box-table fallback. Fixes
   the static-token 401 race between concurrent runs.
5. AWS state creds via Teleport Workload Identity (`terraform-state-s3` →
   `AWS_WEB_IDENTITY_TOKEN_FILE` + role `teleport-terraform-state`), then
   optional extra WI legs (`extra_workload_identities`, multiline
   `selector=ENV_VAR=/dest/dir`).
6. Optional per-node SSH tunnels + temp root ed25519 key + ssh-agent
   (`node_ssh_tunnels: true`; requires `nodes.json`) — bpg/proxmox native
   SSH transport (snippets / disk imports). With `node_ssh_direct: true`
   the forward is opened AFTER the key injection, by a plain `ssh -L` to
   the node's internal `address`, and Teleport is left with the auth
   bootstrap only (pveum mint + key injection).
7. Proxmox API tunnel — **the LAST `tsh ssh` before terraform**, with
   `--no-resume` (additional tsh connections can kill a resumable
   background tunnel). Forward is `-L <local>:localhost:8006`: LOCAL port =
   `nodes.json .api_tunnel_port // 8006`, REMOTE side fixed 8006 (Proxmox
   always listens 8006 — removes the triple port coupling; all repos are
   8006:8006 today). Host = `proxmox_host` input or `nodes.json
   .nodes[0].teleport_host`. Readiness = TCP accept + unauthenticated
   `curl -sk https://127.0.0.1:<port>/api2/json/version` (proves HTTPS
   end-to-end through the tunnel, not just the local bind); after 15 failed
   attempts → `::error` + exit 1.
8. `hashicorp/setup-terraform@v4` (`terraform_version`, wrapper off) →
   `init` → `plan -out=tfplan` (optional `-parallelism` on BOTH plan and
   apply; `-replace` args composed WITHOUT eval, plain-bash whitespace trim
   that PRESERVES double quotes — `module.sql["sql01"]` stays intact) →
   `show` to `plan-<r>-<e>-<s>.txt` → apply
   (`action: apply`) → artifact upload (always, 30d) → cleanup (always:
   token remove, temp-key removal, agent + all tunnel PIDs) → step summary.

Env dir: `terraform/environments/<env_dir || environment>` (vpn eu:
`env_dir: eu-omega`).

### Sensitive-plan masking (`mask_sensitive_jq_path`)

For providers that don't mark secrets Sensitive (gravitational/teleport's
`registration_secret`): plan stdout is suppressed, every value matched by
`.. | objects | <path>? // empty` in the plan JSON is `::add-mask::`-ed, and
the plan text artifact is sed-redacted. Pass e.g. `.registration_secret`
(haproxy). Empty = normal plan output.

### Rolling apply (`rolling: true`)

haproxy-shaped: applies `<rolling_module_prefix>["X"]` targets one at a time
with `rolling_interval` seconds between, ordered privates → publics → api,
reverse-numeric within each role (pairs with ansible `serial: 1`).
Auto-falls back to a normal parallel apply when the plan touches anything
outside the prefix. Caveat ported verbatim from the source: VM keys not
matching one of the three role greps are silently dropped from the rolling
order.

## Input contract (terraform-run)

| input | type | default |
|---|---|---|
| `region`, `environment`, `site` | string | required |
| `env_dir` | string | `''` → `environment` |
| `action` | string | `plan` |
| `terraform_version` | string | `1.14.6` |
| `replace_targets` | string (comma-sep) | `''` |
| `parallelism` | string | `''` (tf default; mssql `1`, haproxy `20`) |
| `vault_mode` | string | `none` \| `public` \| `tunnel` |
| `vault_addr` | string | `https://vault.maestra.io` |
| `teleport_app` | string | `''` (tunnel mode, e.g. `vault-omicron`) |
| `vault_role` | string | `''` |
| `vault_secrets` | string | `''` (vault-action map, `TF_VAR_*` export names) |
| `proxmox_token_prefix` | string | **required** |
| `proxmox_host` | string | `''` → nodes.json[0] |
| `api_tunnel` | boolean | `true` (local port = `.api_tunnel_port // 8006`, remote fixed `8006`; TCP + unauth `/api2/json/version` readiness, fail-fast) |
| `node_ssh_tunnels` | boolean | `false` |
| `node_ssh_direct` | boolean | `false` — forward node + API ports with plain `ssh -L` to each node's nodes.json `address` instead of `tsh ssh -L`. Provider contract unchanged (still `127.0.0.1:<ssh_tunnel_port>`); requires `runs_on` on an in-network ARC set, `node_ssh_tunnels: true`, and an `address` key on every node |
| `runs_on` | string | `ubuntu-latest` — or an ARC scale set (`us-omega-lw-runners`, `us-omicron-lw-runners`) |
| `mask_sensitive_jq_path` | string | `''` |
| `rolling` / `rolling_interval` / `rolling_module_prefix` | bool/number/string | `false` / `180` / `module.haproxy` |
| `extra_workload_identities` | string | `''` (`selector=ENV_VAR=/dest/dir` lines) |
| `extra_env` | string | `''` (KEY=VALUE lines → GITHUB_ENV) |
| `gh_environment` | string | `''` — **passed VERBATIM by caller; naming differs per repo (dashes `us-omega-lw` vs underscores `us_omega_lw`); central never derives** |
| `artifact_name` | string | `''` → `tf-plan-<r>-<e>-<s>` |
| `teleport_join_token` | string | `github-actions-infra-deploy` |
| `teleport_fqdn` | string | `teleport.maestra.io:443` |

## terraform-pr

Caller keeps the trigger (`paths: terraform/**` +
`.github/workflows/terraform-*.yml`), `concurrency:
terraform-pr-<PR#> / cancel-in-progress: true`, `permissions: contents:
read + id-token: write + pull-requests: write`, and `secrets: inherit` on
the uses-job; passes `envs` (JSON array). Caller-level permissions CAP the
called workflow's token — ansible-phase evidence: dropping
`pull-requests: write` at the caller caps the central comment job → 403 on
the sticky comment.
Per-row overrides: `env_dir`, `proxmox_host`, `proxmox_token_prefix`,
`vault_*`, `parallelism`, `mask_sensitive_jq_path`, `extra_env`,
`extra_workload_identities`, `replace_targets`, `runs_on`. Booleans
(`node_ssh_tunnels`, `api_tunnel`, `node_ssh_direct`) are workflow-wide
only. `runs_on` is per-row on purpose: an omicron row must not execute on
an omega runner, and rows in a region with no ARC set (eu) stay hosted.
`fmt` and `comment` stay on `ubuntu-latest` — neither touches infra. Jobs: `fmt`
(`terraform fmt -check -recursive terraform/`) ∥ `plan` matrix (fail-fast
false, artifacts `tf-plan-<r>-<e>-<s>`) → `comment` (always()): sticky
comment, marker `<!-- terraform-plan-diff -->`, `comment_max_chars` default
`4000` (haproxy passes `55000`), filename-derived row labels (suffix
tolerated), change detection = `!('No changes.' || 'Your infrastructure
matches the configuration.')`.

## terraform-manual

Reusable forwarding leg over the full runner surface. Per-repo dispatch
callers keep their own `workflow_dispatch` inputs and compute the
`gh_environment` gate expression themselves (nat/vpn dashes, AD underscores)
— passed verbatim. **AD skips central-manual**: its manual caller routes
through the repo shim instead (manual → shim → central-run, depth 3), so
the dual-vault env-conditional expressions live in exactly 2 places (shim +
PR matrix rows), not 3. Only nat and vpn consume this workflow.

## Per-repo pins

| repo | token prefix | node_ssh_tunnels | vault | specials |
|---|---|---|---|---|
| maestra-nat-gateway | `nat-gateway-terraform` | true | none | `extra_env: TF_VAR_teleport_token=maestra-nat-gateway-ssh-nodes` |
| vpn-maestra | `vpn-terraform` | true | none | `env_dir: eu-omega` for the eu row; `extra_env: TF_VAR_teleport_token=maestra-vpn-ssh-nodes`; deploy leg `terraform-us-omicron-lw` is a **LIVE ungated auto-apply canary on main** (re-enabled for #142) — only us-omega + eu tf legs are `if: false`; **MANDATORY** manual omicron plan before the first post-migration `terraform/**` push |
| mssql-maestra | `mssql-terraform` | false | dual: omicron tunnel `vault-omicron`/`mssql-maestra-deploy-github-ci`; omega public/`mssql-maestra-github-ci`; secret map (2 lines): `infrastructure/data/active-directory/domain-join windows_admin_password \| TF_VAR_admin_password ;` + `infrastructure/data/active-directory/domain-join domain_join_password \| TF_VAR_domain_join_password` | `parallelism: "1"` (now applies to plan too); PR matrix omicron-only — the single row carries the full tunnel quad + 2-line secret map; **branch master** |
| active-directory-maestra | `ad-terraform` | false | dual — PR matrix has TWO LIVE rows with per-row routing: omicron tunnel (`http://127.0.0.1:8200` / `vault-omicron` / `active-directory-maestra-deploy-github-ci`), omega public (`https://vault.maestra.io` / `active-directory-maestra-github-ci`, no teleport_app); both rows `vault_secrets: infrastructure/data/active-directory/domain-join windows_admin_password \| TF_VAR_admin_password` | `replace_targets`; manual gate `us_omega_lw` (underscores); manual routes via the REPO SHIM (skips central-manual) |
| haproxy-maestra | `haproxy-maestra-terraform` | true (omega; omicron auto-skips — no nodes.json) | none | FULL pin list on the PR caller: `proxmox_host` per row; `parallelism: "20"`; `mask_sensitive_jq_path: .registration_secret` — **WARNING: omitting it fails SILENTLY (cleartext registration_secret in logs + PR comment)**; `rolling` on omicron deploy leg; `extra_workload_identities: cert-manager=TF_VAR_route53_web_identity_token_file=/tmp/tbot-route53`; `extra_env` BOTH lines: `TF_VAR_teleport_token=haproxy-maestra-ssh-nodes` + `TF_VAR_proxmox_api_endpoint=https://127.0.0.1:8006/`; `comment_max_chars: "55000"` |

Full migration mapping, wiring checklist and intended behavior deltas:
see the phase-2 migration plan (tf-dedup/MIGRATION-TF.md at design time;
folded into PR descriptions on landing).

## Learnings carried over from the ansible phase

- tbot configs MUST use `storage: type: memory` (hosted runners can't write
  `/var/lib/teleport`).
- Teleport identity env exported on every executing step's environment.
- No `|| true` on critical steps; probe fallbacks must not launder failures.
- `timeout`, not `gtimeout` (Linux runners).
- Caller-level `permissions` CAP the called workflow's token: dropping
  `pull-requests: write` at the caller caps the central comment job → 403.
- Action pins: checkout v6, cache v6, setup-terraform v4, upload-artifact v7,
  download-artifact v8, github-script v9, teleport setup v1 / auth v2,
  vault-action v4 (prod-proven: ansible central v1.0.5 runs it green in
  tunnel mode on mssql/AD ansible PRs) — `# TODO: SHA-pin via Renovate on
  landing`.

## Cutover hygiene

At each repo's cutover, one-time MANUAL removal of the now-orphaned STATIC
pveum token on the mint host(s): `pveum user token remove ci@pve
<static-name>` — static names `nat-gateway-terraform`, `vpn-terraform`,
`haproxy-maestra-terraform` (mssql/AD were already per-run). Per-run tokens
from hard-killed runners can accumulate — inert; optional periodic sweep.
