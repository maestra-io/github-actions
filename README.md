# GitHub Actions

## Releases and versioning

**Every push to `main` cuts a release.** [`.github/workflows/release.yml`](.github/workflows/release.yml)
reads the commits since the previous tag, creates an annotated `vX.Y.Z`, force-moves the major alias
`vX`, and publishes a GitHub Release with generated notes. Nobody tags this repo by hand.

The bump comes from [Conventional Commits](https://www.conventionalcommits.org/) when the range has
any, and falls back to `patch` when it does not:

| in the range since the last tag | bump |
| --- | --- |
| `<type>(<scope>)!:` in a subject, or `BREAKING CHANGE:` in a body | major |
| `feat:` / `feat(<scope>):` | minor |
| anything else, including a range with no conventional subject at all | patch |

This repo squash-merges with `COMMIT_OR_PR_TITLE`, so in practice the subject the bump is read from
is the **PR title** for a multi-commit PR and the **commit subject** for a single-commit one. Write
the one that will land.

The fallback is deliberate. Fewer than half the subjects in this repo are conventional, and a tool
that releases *only* on `feat:`/`fix:` would cut no tag for most merges — which is the failure this
replaced. The rules live in [`ci/next-version.sh`](ci/next-version.sh) and are tested by
[`ci/tests/test-next-version.sh`](ci/tests/test-next-version.sh) (run by `selftest` on every PR that
touches `ci/`).

### How consumers should pin

**Composite actions** (and every other action, ours and external) — a full commit SHA with the
release tag as a comment. The org is moving to `sha_pinning_required` (issues-maestra#1649), which
rejects any action referenced by a tag; Renovate (`helpers:pinGitHubActionDigests`) bumps the SHA and
the comment together:

```yaml
uses: maestra-io/github-actions/tbot-join@<40-hex sha> # v1.46.0
```

`pinact run` writes this form from a tag. The reusable workflows of this repo call its composite
actions the same way, so a change to a composite action reaches them only once that SHA is bumped.

**Reusable workflows** — a release tag. GitHub's SHA-pinning policy exempts reusable workflows, and
Renovate bumps the tag:

```yaml
uses: maestra-io/github-actions/.github/workflows/terraform-run.yml@v1.1.7
```

If you would rather not review a Renovate PR per patch, `@v1` is also valid — a moving alias that
only goes forward inside major 1. You give up the record of *which* release ran, so prefer the full
`vX.Y.Z` tag for anything that touches production.

**The `maestra.infra` ansible collection** — `ansible-galaxy` takes any git ref in `version:`, so
pin the tag rather than `main`:

```yaml
- name: https://github.com/maestra-io/github-actions.git#/ansible/collections/maestra/infra/
  type: git
  version: v1.1.7
```

> `@main` is never a pin. It re-resolves on every run, so a consumer's behaviour changes on a merge
> here that nobody reviewed against that consumer. Pin `@main` only where the coupling is genuinely
> intentional and stated.

### Breaking changes

A `!` or a `BREAKING CHANGE:` footer cuts `v2.0.0` and moves the alias `v2` — it does **not** move
`v1`, so consumers on `@v1` stay where they are until they migrate. Consumers on a full `vX.Y.Z` tag
are unaffected until their Renovate PR is reviewed. Mark a change breaking whenever an input is removed
or renamed, a default changes meaning, or a required secret appears.

## Octopus Deploy Package and Release

This action creates an Octopus Deploy package, uploads it, and creates a release in a single step.

### Usage

```yaml
- name: Deploy to Octopus
  uses: maestra-io/github-actions/octopus-package-release@main
  with:
    octopusProject: my-project
    version: ${{ steps.release-number.outputs.release-number }}
    folderToPack: helmfile/**
    space: Default
    releaseNotes: ${{ steps.create-release.outputs.release-notes-body }}
    OCTOPUS_CLI_API_KEY: ${{ env.OCTOPUS_API_KEY }}
    OCTOPUS_CLI_SERVER: ${{ env.OCTOPUS_CLI_SERVER }}
```

### Inputs

- `octopusProject`: Octopus project name (required)
- `version`: Package and release version (required)
- `folderToPack`: Folder to include in package, e.g., `helmfile/**`, `terraform/**` (required)
- `space`: Octopus space name (optional, defaults to "Default")
- `releaseNotes`: Release notes for the Octopus release (optional)
- `OCTOPUS_CLI_API_KEY`: Octopus API key (required)
- `OCTOPUS_CLI_SERVER`: Octopus server URL (required)

### Outputs

- `package-path`: Path to the created package file

### Example

```yaml
- name: Deploy with release notes
  uses: maestra-io/github-actions/octopus-package-release@main
  with:
    octopusProject: shopify-webhooks
    version: 1.2.3
    folderToPack: helmfile/**
    space: Production
    releaseNotes: "Bug fixes and performance improvements"
    OCTOPUS_CLI_API_KEY: ${{ secrets.OCTOPUS_API_KEY }}
    OCTOPUS_CLI_SERVER: https://octopus.mindbox.ru
```

## Push to AWS ECR repositories

This action pushes multiple Docker images to AWS ECR repositories.

### Usage

```yaml
jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write   # keyless mode: GitHub OIDC -> Teleport image-push bot
    steps:
      - uses: actions/checkout@v4
      # ... build local/repo1:latest, local/repo2:latest, local/repo3:latest
      - name: Push to ECR
        uses: maestra-io/github-actions/push-to-aws-ecr-repository@main
        with:
          awsRegion: us-west-2
          awsOrganizationId: o-example123456
          repositories: 'repo1,repo2,repo3'
          localTag: 'latest'
          targetTag: 'v1.0.0'
```

### Inputs

- `awsAccessKey` / `awsSecretKey`: static IAM keys. Leave both **empty** (preferred, default) to
  authenticate through Teleport workload identity instead: GitHub OIDC joins the `image-push` bot,
  whose JWT SVID assumes `role/teleport-image-push` (same chain as `bake-oci-manifests`). The job
  needs `permissions: id-token: write`, and the repository needs a token in fluxcd
  `iota/us-iota-lw-kube-infra/teleport-maestra/operator-crs/image-push-tokens.yaml`. Static keys are
  being retired ([issues-maestra#1455](https://github.com/maestra-io/issues-maestra/issues/1455)).
- `teleportToken`: join token for the keyless mode. Default `image-push-github-actions-<repository name>`.
- `teleportFqdn`: Teleport proxy, default `teleport.maestra.io:443`.
- `awsRoleArn`: role assumed in the keyless mode, default `arn:aws:iam::515260921971:role/teleport-image-push`.
- `awsRegion`: AWS Region (required). Since phase 6 of the ECR migration
  ([issues-maestra#1354](https://github.com/maestra-io/issues-maestra/issues/1354)) a stale
  `eu-central-1` is normalised to `us-west-2` with a workflow warning — the EU registry is frozen
  and read by nothing.
- `awsOrganizationId`: AWS Organization ID for ECR policy (required)
- `repositories`: Comma-separated list of repository names (required)
- `localTag`: Tag of locally built images (`local/<repository>:<localTag>`). Required with `push: true`.
- `targetTag`: Target tag for all ECR repositories (required)
- `push`: `true` (default) tags and `docker push`es the local images; `false` stops after the login
  and the repository creation, so the caller pushes from BuildKit (see [Push from BuildKit](#push-from-buildkit)).

### Outputs

- `registry`: the ECR registry host the action logged in to (`515260921971.dkr.ecr.us-west-2.amazonaws.com`).

### Push from BuildKit

A fresh runner's docker daemon (overlay2) holds no registry metadata for the layers BuildKit
built, so `docker push` uploads every layer even when ECR already stores all but the changed
ones (data-mesh-algs-413, 22.10.2026: 81 of 85 layers identical between releases, 2.3 GB
uploaded for 3 MB of change, 100 s of `load: true` plus 3 min of push per release). BuildKit's
own push asks the registry about every blob first and uploads only the missing ones. The shared
workflows (`service-build.yml`, `dotnet-service-build.yml`, `mcf-build.yml`) build once with
`outputs: type=image,push=false`, call this action with `push: false`, and push with a second,
fully cached `docker/build-push-action` run (`push: true`, tag `${registry}/<repository>:<tag>`).
`SOURCE_DATE_EPOCH` (the commit time) keeps the manifest digest reproducible, so a re-run finds
its own image under the immutable tag and skips the push instead of failing on `TAG_INVALID`.
A rebuild with another digest is also skipped (the stored image is kept) when the stored
image's `org.opencontainers.image.revision` label is this commit, e.g. a retry after a spot
interruption killed the job after its push; any other image under the tag fails the job:

```yaml
- uses: docker/build-push-action@v7.4.0
  id: build
  env:
    SOURCE_DATE_EPOCH: ${{ steps.epoch.outputs.value }}
  with:
    provenance: false # an attestation index would change the digest on push
    outputs: type=image,push=false
    tags: local/my-service:${{ steps.v.outputs.release }}
- uses: maestra-io/github-actions/push-to-aws-ecr-repository@v1
  id: ecr
  with:
    awsRegion: us-west-2
    repositories: my-service
    targetTag: ${{ steps.v.outputs.release }}
    push: false
- uses: docker/build-push-action@v7.4.0
  env:
    SOURCE_DATE_EPOCH: ${{ steps.epoch.outputs.value }}
  with:
    provenance: false
    push: true
    tags: ${{ steps.ecr.outputs.registry }}/my-service:${{ steps.v.outputs.release }}
```

### Prerequisites

Before running this action, ensure that:
1. Docker images are built locally with the specified `localTag`
2. Images should be tagged as `local/{repository-name}:{localTag}`
3. AWS credentials have appropriate ECR permissions

### Tag immutability

A repository the action has to create is created `IMMUTABLE_WITH_EXCLUSION`
([`create-repository.sh`](push-to-aws-ecr-repository/create-repository.sh)): a release tag can
never be overwritten with a different image (`TAG_INVALID`), while re-pushing the identical image
still succeeds. Only `latest` stays overwritable — the one moving tag callers push or mirror. Every
app repository in `515260921971` / `us-west-2` is immutable since 2026-10-09, when a re-minted
release number silently overwrote already-released images (live default exclusions there: `latest`
and cosign's `sha256-*`; these actions do not sign, so they skip the latter). Existing
repositories are not touched. A runner whose aws-cli predates the exclusion filters creates the
repository `MUTABLE` with a workflow warning. No extra IAM: `ecr:CreateRepository` covers the flags.

### Example

If you have three services: `api`, `frontend`, and `worker`, you would:

1. Build your images locally:
   ```bash
   docker build -t local/api:latest ./api
   docker build -t local/frontend:latest ./frontend
   docker build -t local/worker:latest ./worker
   ```

2. Use the action (job `permissions` as in [Usage](#usage): `id-token: write`):
   ```yaml
   - uses: maestra-io/github-actions/push-to-aws-ecr-repository@main
     with:
       awsRegion: us-west-2
       awsOrganizationId: o-example123456
       repositories: 'api,frontend,worker'
       localTag: 'latest'
       targetTag: 'v1.0.0'
   ```

This will push all three images to their respective ECR repositories with the `v1.0.0` tag.

### Sign and attest the pushed image

[`sign-image`](sign-image/action.yml) runs after the push: cosign 3 keyless-signs the digest
(GitHub OIDC -> Fulcio, Rekor) and attests a CycloneDX SBOM of it (syft), both stored next to the
image as OCI referrers (`aws ecr list-image-referrers`, artifactType
`application/vnd.dev.sigstore.bundle.v0.3+json`, annotation `dev.sigstore.bundle.predicateType`
`https://sigstore.dev/cosign/sign/v1` or `https://cyclonedx.org/bom`). No tags are written, so the
immutable repositories need no `sha256-*` exclusion for it. The job needs `id-token: write` and the
registry login above. Best-effort: a Fulcio/Rekor/syft failure is a warning and the `status` output
(`sbom+signature` / `signature` / `none`) says what landed
([issues-maestra#1648](https://github.com/maestra-io/issues-maestra/issues/1648)).

```yaml
- uses: maestra-io/github-actions/sign-image@<sha> # vX.Y.Z
  with:
    image: ${{ steps.ecr.outputs.registry }}/my-service
    digest: ${{ steps.push.outputs.digest }}
```

A job that pushes several images passes `refs:` instead, one `<image>@sha256:<digest>` per line.

Verify: `cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com
--certificate-identity-regexp '^https://github\.com/maestra-io/' <image>@<digest>`
(`verify-attestation --type cyclonedx` for the SBOM).

### Second region

The dual-push of the ECR eu-central-1 → us-west-2 migration
([issues-maestra#1354](https://github.com/maestra-io/issues-maestra/issues/1354), phases 3–6) is
gone from `push-to-aws-ecr-repository` and `bake-oci-manifests`: us-west-2 is the only registry.
The standalone `mirror-to-secondary-ecr` action followed on 22.10.2026 once its last caller
dropped the step.

## Bake OCI manifests artifact

Bakes a microservice's `kustomization/` tree into an OCI artifact at `${ECR_REGISTRY}/<service>-manifests:<tag>`, cosign-keyless-signs the digest before `<tag>` exists (push under the non-semver staging tag `bake-<tag>-<sha>`, sign, `cosign verify` with the identity the clusters check, then tag; the staging tag stays; a failed sign leaves no `<tag>` for Kargo, [issues-maestra#1680](https://github.com/maestra-io/issues-maestra/issues/1680)), and verifies the pulled artifact contains no leftover `${APP_PACKAGE_VERSION_TO_BE_REPLACED}` placeholders. This is the GitHub-side half of the **OCI + Kargo** deploy pattern documented in [`maestra-io/fluxcd/docs/microservice-deployment.md`](https://github.com/maestra-io/fluxcd/blob/main/docs/microservice-deployment.md).

### Usage

A complete `.github/workflows/release.yml` for a typical service:

```yaml
name: release
on:
  push:
    tags: ["[0-9]+.[0-9]+.[0-9]+"]
  workflow_dispatch:
    inputs:
      tag:
        description: "Existing semver tag to (re)bake from"
        required: true
permissions:
  contents: read
  id-token: write       # Teleport workload-identity JWT minting
concurrency:
  group: bake-${{ github.ref }}
  cancel-in-progress: false
jobs:
  bake:
    runs-on: ubuntu-latest
    steps:
      - uses: maestra-io/github-actions/bake-oci-manifests@main
        with:
          service: db-migrator
          images: db_migrator_services,db_migrator_migrator
```

The example above suits a **mirrored** repo, where the bare-semver tag is pushed
externally (by the GitLab→GitHub mirror) and triggers this workflow.

For a **GitHub-native** repo (no GitLab mirror), the release tag is created in
the release workflow with `GITHUB_TOKEN`, which cannot trigger a separate
`on: push: tags` workflow. Bake from a `needs: build` job in the same run and
pass the tag explicitly via `tag:`:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      release-number: ${{ steps.release-number.outputs.release-number }}
    steps:
      # ... build + push images to ECR, then create the release/tag ...
  bake:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: maestra-io/github-actions/bake-oci-manifests@main
        with:
          service: shopify-webhooks
          images: shopify_webhooks_services,shopify_webhooks_worker
          tag: ${{ needs.build.outputs.release-number }}
```

### Inputs

- `service`: kebab-case service name. Derives `TELEPORT_TOKEN` (`image-push-github-actions-<service>`) and `IMAGE_MANIFESTS` (`<service>-manifests`). **(required)**
- `images`: comma-separated list of image basenames the action will verify exist in ECR before baking. If any is missing, the bake fails. **(required)**
- `tag`: explicit bare-semver tag to bake. Default `''`. When empty, the tag is taken from the `workflow_dispatch` input (if any) or `GITHUB_REF_NAME` (the tag that triggered the run) — the behaviour for mirrored repos. **Set this for GitHub-native repos** that bake from a `needs: build` job in a push-to-`main` release run: there the release tag is created with `GITHUB_TOKEN`, which GitHub will not let trigger a separate `on: push: tags` workflow, and `GITHUB_REF_NAME` is `main` rather than the semver tag. Precedence: `tag` → `workflow_dispatch.inputs.tag` → `GITHUB_REF_NAME`.
- `flux-version`: flux CLI version, no `v-` prefix. Default `2.8.6`. Change `flux-sha256` with it.
- `flux-sha256`: sha256 of `flux_<flux-version>_linux_amd64.tar.gz`. The default matches `2.8.6`.
- `aws-region`: ECR region. Default `us-west-2` (phase 6 of [issues-maestra#1354](https://github.com/maestra-io/issues-maestra/issues/1354) — the eu-central-1 registry is frozen).
- `ecr-registry`: ECR registry host. Default `515260921971.dkr.ecr.us-west-2.amazonaws.com`.
- `teleport-fqdn`: Teleport proxy. Default `teleport.maestra.io:443`.
- `teleport-token`: Teleport GitHub join token of the image-push bot. Default `''` = `image-push-github-actions-<service>`; `dotnet-service-build.yml` passes the org-wide `image-push-github-actions-maestra-io`.
- `aws-role-arn`: IAM role assumed via Teleport workload-identity. Default `arn:aws:iam::515260921971:role/teleport-image-push`.

### Outputs

- `version`: the resolved bare-semver tag the artifact was baked at.
- `digest`: OCI digest of the pushed manifests artifact (`sha256:...`).

### Prerequisites

1. The source repo's `kustomization/base/helm-release-{app,init}.yaml` uses `packageVersion: "${APP_PACKAGE_VERSION_TO_BE_REPLACED}"` placeholders.
2. A Teleport bot named `image-push-github-actions-<service>` is provisioned on `teleport.maestra.io` with permission to mint workload-identity JWTs for the `image-push` selector against `sts.amazonaws.com`.
3. AWS IAM role `arn:aws:iam::515260921971:role/teleport-image-push` trusts the Teleport SPIFFE issuer (`teleport.maestra.io`).
4. GitLab CI has already pushed all images named in `images:` to ECR for the target tag — the action will refuse to proceed otherwise. See the [`create-gitlab-release.needs` recipe in microservice-deployment.md §3.1](https://github.com/maestra-io/fluxcd/blob/main/docs/microservice-deployment.md) for the gating that prevents this race.
## Teleport join with retries (`tbot-join`)

Every `tbot` join in this repo (the image-push JWT SVID in `push-to-aws-ecr-repository`,
`push-helm-chart-to-aws-ecr` and `bake-oci-manifests`) goes through [`tbot-join/tbot-join.sh`](tbot-join/tbot-join.sh): up to 4
attempts, 5 s / 15 s / 30 s apart, 45 s each (`timeout -k 5 45`), success only when every
expected output is non-empty. Transient failures (Teleport backend switchover, GitHub's OIDC
endpoint or discovery timing out, network) are retried; configuration errors (`token expired or
not found`, `id token claims did not match any allow rules`, `access denied`, a job without
`id-token: write`) fail at once with that reason. The composite actions call the script from
their own ref (`${GITHUB_ACTION_PATH}/../tbot-join/tbot-join.sh`); a workflow uses the wrapper.
Consumers (org-wide code search, confirmed on default branches 2026-10-16):
[`hot-test-publish.yml`](.github/workflows/hot-test-publish.yml) here (`@v1`, Workload Identity +
Vault app join for PR hot-test stands) and `maestra-io/dockerfiles` `.github/workflows/release.yml`
(`@main`, image-push SVID). The build workflows' `kargo-refresh` job, its first user, was removed
2026-10-16 (Warehouses are refreshed by the GitHub org webhook now).

```yaml
- uses: maestra-io/github-actions/tbot-join@v1
  with:
    config: ${{ steps.cfg.outputs.dir }}/tbot.yaml   # oneshot, storage: memory
    require: |
      ${{ steps.cfg.outputs.dir }}/svid/jwt_svid
    label: token my-token        # for messages
    hint: "does my-token exist?" # printed for configuration errors only
    warn-only: false             # true: ::warning:: instead of ::error:: (the step still fails)
```

Tested by [`scripts/test-tbot-join.sh`](scripts/test-tbot-join.sh) (stub `tbot`, run by `selftest`).

## A nora credential for a long build (`nora-session`)

A GitHub OIDC token lives ~5 minutes, and nora checks `exp`. A credential written once
(Maven `settings.xml`, `.npmrc`, bower, a Docker build secret) needs a longer one: the action
exchanges the job's OIDC token at nora (`POST /api/oidc/session`) for a session token, `nrs_…`,
with the token's role and namespace scope, that lives 1 hour (issues-maestra#1649). The
`token` outputs of `go-nora`, `cargo-nora` and `uv-nora` are such session tokens; their
GOAUTH / credential / keyring helpers still mint a fresh OIDC token on every call. A nora
without the exchange (404) or a provider without sessions (403) gets the OIDC token, with a
warning; any other answer fails the step. Needs `id-token: write`.

```yaml
  - uses: maestra-io/github-actions/nora-session@<40-hex sha> # vX.Y.Z
    id: nora
  - run: mvn -s ci-settings.xml -B verify   # <password>${env.NORA_TOKEN}</password>
    env:
      NORA_TOKEN: ${{ steps.nora.outputs.token }}
```

Tested by [`scripts/test-nora-session.sh`](scripts/test-nora-session.sh) (stub `curl`, run by `selftest`).

## Terraform providers through nora (`terraform-nora`)

Every `registry.terraform.io` provider installs from `https://packages.maestra.io/terraform/`
(nora's network mirror: quarantine, versions younger than 3 days hidden), not from the public
registry or a third-party mirror (issues-maestra#1649). Providers from other hosts
(`terraform.releases.teleport.dev`, ...) still install directly. Add it right after
`hashicorp/setup-terraform`; the job needs `id-token: write`:

```yaml
permissions:
  id-token: write
steps:
  - uses: hashicorp/setup-terraform@<sha> # v4.0.1
  - uses: maestra-io/github-actions/terraform-nora@<40-hex sha> # vX.Y.Z
  - run: terraform init
```

It writes a CLI config to `$RUNNER_TEMP/terraform-nora/terraform.tfrc`, exports
`TF_CLI_CONFIG_FILE` (keeping the credentials setup-terraform put in `~/.terraformrc`) and installs
a credentials helper (`~/.terraform.d/plugins/terraform-credentials-nora`) that mints a fresh GitHub
OIDC token (`aud` `packages.maestra.io`) each time Terraform asks, so a second `terraform init`
later in the job does not hit an expired token. A private provider from a local directory:
`fs-mirror-path` + `fs-mirror-include` (e.g. `registry.terraform.io/mindbox-private/*`).

A version younger than 3 days is hidden from nora's version lists, so `terraform init` without a
lock picks the newest older one; a `.terraform.lock.hcl` that pins a younger version fails until it
matures (`host packages.maestra.io rejected the given authentication credentials` is that 403).
Test: `scripts/test-terraform-nora.sh` (selftest).

## Go modules and crates through nora (`go-nora`, `cargo-nora`)

Public Go modules come from `https://packages.maestra.io/go` (nora's proxy of proxy.golang.org;
a version whose `.info` Time is younger than 3 days is refused) and crates.io from
`https://packages.maestra.io/cargo` (sparse index, versions younger than 3 days held), not
straight from upstream (issues-maestra#1649). The job needs `id-token: write`.

```yaml
permissions:
  id-token: write
steps:
  - uses: actions/setup-go@<sha>                                     # Go >= 1.24 (GOAUTH)
  - uses: maestra-io/github-actions/go-nora@<40-hex sha> # vX.Y.Z
    id: nora
  # or, after the Rust toolchain step:
  - uses: maestra-io/github-actions/cargo-nora@<40-hex sha> # vX.Y.Z
    id: nora
  - run: go test ./...        # cargo test --locked
  # An image build: within the hour (the token is a nora session token, see nora-session).
  - uses: docker/build-push-action@<sha>
    with:
      secrets: PRIVATE_PACKAGES_TOKEN=${{ steps.nora.outputs.token }}
```

- `go-nora` exports `GOPROXY` (no `direct` fallback; `GOPRIVATE` modules still come from git)
  and `GOAUTH=$RUNNER_TEMP/go-nora/goauth`, a helper that mints a fresh GitHub OIDC token
  for every `go` process and again after a 4xx.
- `cargo-nora` appends source replacement and
  `credential-provider = ["cargo:token-from-stdout", <helper>]` to `$CARGO_HOME/config.toml`;
  the helper mints a fresh token whenever cargo asks.

In the Dockerfile the token comes as the `PRIVATE_PACKAGES_TOKEN` secret, the same one
`service-build.yml` and `dockerfiles` already pass (a local build without it keeps upstream):

```dockerfile
RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,env=NORA_TOKEN \
    GOPROXY="${NORA_TOKEN:+https://token:${NORA_TOKEN}@packages.maestra.io/go}" go mod download

RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,env=NORA_TOKEN \
    if [ -n "${NORA_TOKEN:-}" ]; then printf '%s\n' '[source.crates-io]' 'replace-with = "nora"' \
      '[source.nora]' 'registry = "sparse+https://packages.maestra.io/cargo/index/"' \
      '[registries.nora]' 'index = "sparse+https://packages.maestra.io/cargo/index/"' \
      'credential-provider = ["cargo:token"]' >> "${CARGO_HOME:-$HOME/.cargo}/config.toml"; \
      export CARGO_REGISTRIES_NORA_TOKEN="Basic $(printf 'token:%s' "$NORA_TOKEN" | base64 | tr -d '\n')"; \
    fi && cargo fetch --locked
RUN cargo build --release --offline
```

Go redacts the userinfo (`token:xxxxx`) in its errors. Tests: `scripts/test-go-nora.sh`,
`scripts/test-cargo-nora.sh` (selftest).

## Python packages through nora (`uv-nora`)

Every Python repo uses uv with a committed `uv.lock` and nora as its only index
(issues-maestra#1649): a version younger than the hold is not served, and nothing falls back
to pypi.org. The index is declared in `pyproject.toml`:

```toml
[[tool.uv.index]]
name = "maestra"
url = "https://packages.maestra.io/simple/"
default = true
```

```yaml
permissions:
  id-token: write
steps:
  - uses: astral-sh/setup-uv@<sha>
    with: { version: "<pinned>" }
  - uses: maestra-io/github-actions/uv-nora@<40-hex sha> # vX.Y.Z
    id: nora
  - run: uv sync --locked && uv run pytest
  # An image build: right after the action (its token is minted there).
  - uses: docker/build-push-action@<sha>
    with:
      secrets: PRIVATE_PACKAGES_TOKEN=${{ steps.nora.outputs.token }}
```

`uv-nora` exports `UV_INDEX_MAESTRA_USERNAME=token` and `UV_KEYRING_PROVIDER=subprocess` and puts
a `keyring` helper on PATH that mints a fresh GitHub OIDC token whenever uv asks (after nora's
401), for nora's URLs only. In the Dockerfile the token is the `PRIVATE_PACKAGES_TOKEN` secret
(`service-build.yml` passes it too):

```dockerfile
# Into the image's own Python (as pip did; --inexact keeps what the base image ships).
ENV UV_NO_CACHE=1 UV_PYTHON_DOWNLOADS=never UV_COMPILE_BYTECODE=1 UV_INDEX_MAESTRA_USERNAME=token \
    UV_PROJECT_ENVIRONMENT=/usr/local
COPY pyproject.toml uv.lock ./
RUN --mount=type=bind,from=ghcr.io/astral-sh/uv:<version>@sha256:<digest>,source=/uv,target=/usr/local/bin/uv \
    --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,required=true \
    UV_INDEX_MAESTRA_PASSWORD="$(cat /run/secrets/PRIVATE_PACKAGES_TOKEN)" \
    uv sync --locked --inexact --no-dev --no-install-project
```

uv is bind-mounted from its image, so nothing of it stays in a layer and no pip is involved (pip
before 23.1 cannot read nora's PEP 691 `dist-info-metadata` objects).

Test: `scripts/test-uv-nora.sh` (selftest).

## Ansible Galaxy through nora

`ansible-pr.yml` and `ansible-run.yml` install Galaxy collections from
`https://packages.maestra.io/ansible/` (`ANSIBLE_GALAXY_SERVER_*`, a GitHub OIDC token): nora
hides versions younger than 3 days, so a range like `>=8.0.0` resolves to the newest mature
release. Roles and collections with a git `src` still come from git.

## Prewarm external images in nora (`nora-image-prewarm`)

nora holds every image digest it sees for the first time for 3 days (issues-maestra#1649). This
action asks `packages.maestra.io` once for each external image a PR brings in, so that clock starts
when the PR opens, not when a cluster first pulls the merged image. One manifest GET per image:
nora dates everything the manifest names (platform manifests, config, layers) at that first sight.
A `tag@sha256` reference is asked by its tag first, then by its digest: with `trust_upstream_dates`
nora dates a tag pull from Docker Hub or quay by the registry's own push date, so an image older
than the quarantine passes at once, and a digest alone carries no tag to look up.
Images come from `images` (one per line) and/or `flate-diff`, a `flate diff ... -o json` file (the
images a changed object's `new` has and its `old` lacks). Hosts are mapped to nora prefixes as in
fluxcd `base/kyverno-nora-pull-through`; our ECR and other hosts are skipped. nora or the token
service being unreachable is a warning, never a failure (an unreachable image is also a row in the
step summary). It does fail on a caller error: no `id-token: write` permission, or a `flate-diff`
file that is missing or not JSON (fluxcd calls it with `continue-on-error`). Needs `id-token: write`:

```yaml
permissions:
  id-token: write
steps:
  - uses: maestra-io/github-actions/nora-image-prewarm@<40-hex sha> # vX.Y.Z
    with:
      images: |
        ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1
```

Test: `python3 nora-image-prewarm/prewarm.py --self-test` (selftest).

## Gitleaks on pull requests (`gitleaks.yml`)

The reusable workflow [`gitleaks.yml`](.github/workflows/gitleaks.yml) runs the official
[`gitleaks/gitleaks-action`](https://github.com/gitleaks/gitleaks-action) (v3) on a pull
request. One job, `gitleaks` (check name `gitleaks / gitleaks` with the caller below),
skipped outside `pull_request`.

A repo enables the scan with its own workflow, `.github/workflows/gitleaks.yml`; none
of the shared workflows here (the service builds, `mcf-build.yml`, the package
publishers, `helm-chart.yml`, `frontend-codegen.yml`, `terraform-pr.yml`,
`ansible-pr.yml`, `pr-checks.yml`) runs it:

```yaml
name: gitleaks
on: pull_request
permissions: { contents: read, pull-requests: write }
jobs:
  gitleaks:
    uses: maestra-io/github-actions/.github/workflows/gitleaks.yml@main
    secrets: inherit   # GITLEAKS_LICENSE, an org secret
```

- **Secret**: gitleaks-action exits 1 on an organization repo without `GITLEAKS_LICENSE`
  (`secrets: inherit`, or `secrets: { GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }} }`).
- **Permissions** come from the calling workflow (this one declares none): `contents: read`
  and `pull-requests: write` (the PR's commit list on a private repo, and the review
  comments).
- **What is scanned**: the PR's commits, `--no-merges --first-parent <first>^..<last>`,
  on a full-depth checkout; never the whole tree. **Limit**: the action reads only the
  first 30 commits of the PR, so a longer PR is scanned up to its 30th commit.
- **Findings**: red job, listed (redacted) in the job summary and a review comment on
  the PR per finding, and the SARIF report as a run artifact (the action's defaults).

The action installs the pinned gitleaks release (`GITLEAKS_VERSION: 8.30.1`); a new one arrives only through a reviewed bump. One input,
`ref`: the ref of this repo the central config is read from (default `main`).

**Config**: only the central [`gitleaks/gitleaks.toml`](gitleaks/gitleaks.toml) (gitleaks'
default rules plus allowlists that apply to any repo), passed as `GITLEAKS_CONFIG`. A repo's
own gitleaks config is not read; a project-specific allowlist is added here.

A single accepted finding goes to `.gitleaksignore` at the repo root, one fingerprint
`<commit>:<file>:<rule-id>:<line>` per line.

`pr-checks.yml` has no gitleaks step any more; its `gitleaks` input is deprecated and
ignored (it stays declared so callers that still pass it do not break).
`pr-checks/gitleaks.toml` stays only for the callers that pin an older `pr-checks.yml`.

## Test results ingest (flaky-test telemetry)

`test-results-ingest` turns the TRX / JUnit files of a job into one JSON row per
test result (repo, workflow, job, run id and attempt, sha, branch, test id,
outcome, duration, failure hash) and pushes them to the ci-telemetry
VictoriaLogs on us-iota-lw-kube-infra
([issues-maestra#1592](https://github.com/maestra-io/issues-maestra/issues/1592)).
`dotnet-service-build.yml`, `nuget-package-publish.yml` and the `test`, `functional` and `e2e`
jobs of `mcf-build.yml` call it after every test run (`test` sends the JUnit the shared
vitest preset writes to `reports/` in CI; a repo on an older preset or with its own
`reporters` sends nothing); the bearer comes from Vault role
`ci-test-results-ingest`, bound to the workflow files in its `job_workflow_ref`
(fluxcd `vault-server/central-auth.yaml`; a workflow missing there gets no rows),
so the job needs `id-token: write` and nothing else. Call it with
`continue-on-error: true`: telemetry never fails a build. Query:
datasource `victorialogs-ci-telemetry`, LogsQL
`_time:14d | stats by (repo, sha, test_id) count_uniq(outcome) n | filter n:>1`.

## Build and publish workflows (packages.maestra.io, ECR, Kargo)

Reusable workflows for repositories built on GitHub Actions instead of GitLab
([issues-maestra#1442](https://github.com/maestra-io/issues-maestra/issues/1442)).
They run on the RunsOn pools (`pool=build` 8 vCPU/32 GiB, `pool=small`), cache
through the Magic Cache (`type=gha` lands in S3) and need no stored secret except
the PyPI token: packages go to nora with the GitHub OIDC token, images to ECR
through the Teleport image-push bot. Inputs, jobs and auth are documented at the
top of each file.

Layer cache freshness: a Dockerfile stage that installs from apt/apk or the network
without a pin declares `ARG BASE_REFRESH` directly before its first such `RUN`;
`dotnet-service-build.yml` and `service-build.yml` pass the ISO week (`YYYY-Www`, e.g. `2026-W45`) as that
build-arg, so the stage is rebuilt on the first build of a new week instead of being served
from the layer cache (sticky disk, `type=gha`) for as long as it lives. A Dockerfile without
the ARG only gets BuildKit's "build-arg not consumed" warning.

| workflow | does | GitLab original |
| --- | --- | --- |
| [`dotnet-service-build.yml`](.github/workflows/dotnet-service-build.yml) | `version` → `test` → `images` (matrix) → `release` → `bake`; input `graphql-schemas: true` downloads the StrawberryShake schemas named by the repo's `.graphqlrc.json` files once in `test` and hands them to `images` (GitHub OIDC → auth-jwt omega JWT, client `github-dotnet-graphql-schema`, bound to this workflow at `@refs/heads/main`: call it at `@main`, a tag or SHA is rejected by auth-jwt) | dotnet-service-cicd-components release-template, create-release-number, docker-push-to-all, maestra-bake-oci-manifests |
| [`service-build.yml`](.github/workflows/service-build.yml) | same jobs as `dotnet-service-build.yml` for any language: `test` runs the repo's `test-command` (optional `python-version` / `node-version`) or a Dockerfile `docker-test-target`; build secrets under the Dockerfile's own ids (`build-secret-ids`) | docker-push-to-all, maestra-bake-oci-manifests, create-release-number, the repo's own GitLab test jobs |
| [`nuget-package-publish.yml`](.github/workflows/nuget-package-publish.yml) | restore, build, test, pack, `dotnet nuget push` | dotnet-nuget-cicd-components |
| [`npm-package-publish.yml`](.github/workflows/npm-package-publish.yml) | `npm ci`, lib@3 checks (`checks` input: graphql-codegen, check-types, check-scripts, check-styles, test; `--if-present`, all reported; check-scripts with `eslint --concurrency=auto` on ESLint >= 9.34), optional PR coverage comment (`report-coverage`), `npm run release` (semantic-release); RunsOn `pool` input `small` (default) or `build` | frontend-ci-components `templates/lib` |
| [`python-package-publish.yml`](.github/workflows/python-package-publish.yml) | poetry/uv build, test, `twine upload`; uv, poetry and twine through nora (`uv-nora`) | — |
| [`mcf-build.yml`](.github/workflows/mcf-build.yml) | micro-frontends: `install` (fails when `package.json` and `package-lock.json` disagree; node_modules cached by lockfile hash, `npm ci` only on a miss; then codegen in the same job: GitHub OIDC → auth-jwt omega JWT → artifact `codegen`) → `checks`, `test`, `build` → `image` (rclone + `<static-prefix>`, default `v2_static/<mcf>`; `static-prefix: v2_static/core`, `static-manifest: manifest.json` and `static-version-file: build-info.json` for the admin shell frontend-core-v2; the defaults are `mf-manifest.json` and no version file) → `deps-image` (`<image>-with-deps:<release>`: the sources and `node_modules`, uid 10001, no `.git`; chart `mcf-schema-check` runs the schema check from it at promotion, [issues-maestra#1573](https://github.com/maestra-io/issues-maestra/issues/1573); after `image`, as ECR tags are immutable and a re-run reuses the release number) and, with `tests/e2e/`, `e2e-image` (`<image>-e2e:<release>`, [below](#mcf-build-e2e-image)) → `release` → `bake`, `sourcemaps` (Datadog US3, key from the central Vault); the bucket upload runs at promotion from the MCF's own `kustomization/`. With `tests/`: `tests-install`, `tests-checks` and, after `build`, `functional` (Playwright against the built static, [below](#mcf-build-tests-and-functional-tests)), and on pull requests `e2e-stand` → `e2e` (Playwright against the PR's e2e stand, input `e2e`, [below](#mcf-build-e2e-stand-and-e2e-tests)). Input `hot-test-pages` goes to `hot-test-publish.yml` as `pages`: more pages of the hot-test stand linked from the PR. On pull requests `pr gate` is the check a branch ruleset requires (`build / pr gate`): red when a PR job failed or was cancelled; `functional` and `e2e` count only with `functional-required` / `e2e-required` | frontend-ci-components `templates/mcf` (mcf@3) |
| [`hot-test-publish.yml`](.github/workflows/hot-test-publish.yml) | hot-test stand of a pull request ([issues-maestra#1574](https://github.com/maestra-io/issues-maestra/issues/1574)): the PR's static artifact + an entry from `frontend-entry-static-builder --single-run` with the PR's manifest → R2 `admin-hot-test-static-omicron-wnam/hot-test-<repo>-pr-<N>/` (Teleport GitHub join from the PR → Vault omicron → 10-minute editor keys); the stand URL `https://hot-test-<repo>-pr-<N>.testing-env.omicron.maestra.io` is in the PR as a deployment of environment `hot-test` and in the job's step summary. Called by `mcf-build.yml` on pull_request (input `hot-test`) and by the legacy admin monorepo's own `pr.yml` (`static-prefix: public`, `static-manifest: ""`: its dist goes to `public/` of the PR folder, the entry is the released shell, and the backend links `/public/...` from the stand's host on `X-Testing-Frontend`); the routes come from the builder's chart per open PR. Input `stand-prefix` (default `hot-test`) is the first word of the stand name, environment and bucket folder: `mcf-build.yml` calls the workflow a second time with `e2e` for the [e2e stand](#mcf-build-e2e-stand-and-e2e-tests). Input `pages` (one `<name> <path>` per line, default none): once the stand answers, each page gets its own deployment of environment `<stand-prefix>-<name>` with the url `<stand url><path>`, so the PR links it next to the stand (frontend-email-editor: `standard-blocks /email-editor/common-block-templates-preview?standardFlexBlocks=true`); like the stand's deployment it needs no token permission. Outputs: `url`, and `route` (`true` once the stand's `/entry/index.html` answered 200, `false` when the static is published but fluxcd has no route for it: ⚠️, the job stays green). Inputs: `bucket` (stands' bucket, write), `base-static-url` (release static the entry is built from), `hot-test-domain`, `static-prefix` (the PR's own folder, default `v2_static/<mcf>`, the module federation folder; a repo whose files live elsewhere — `frontend` `public`, `frontend-core-v2` `v2_static/core` — sets the same path as `staticPrefix` in its fluxcd registration, which the stand's route sends to the PR folder), `static-manifest` (default `mf-manifest.json`, the entry's override; empty for no manifest) and `static-version-file` (default none); under `static-prefix: v2_static/core` the two are frontend-core-v2's `manifest.json` and `build-info.json` and become the builder's core overrides; the tenant and the cluster's copies of these addresses live only in fluxcd (component `base/microfrontend/hot-test`). After the route is up the job compares every release manifest the entry was built from (`v2_static/core/manifest.json` and `v2_static/<mcf>/mf-manifest.json` of each MCF in its `entry/mcf-manifests.json` but those under `static-prefix`) through the stand with the ones under `base-static-url`: another release bucket in the cluster's `baseStaticDomain` (first differing path in the summary) or a non-200 from the stand is ❌ and fails the job | frontend-ci-components mcf@3 hot-test environments |
| [`frontend-codegen.yml`](.github/workflows/frontend-codegen.yml) | one job `codegen` for a frontend with its own pipeline (maestra-io/frontend): restores the `install` job's `node_modules` cache, GitHub OIDC → auth-jwt omega JWT (client `github-frontend-graphql-schema`, bound to this workflow at `@refs/heads/main`) → `npm run graphql-codegen`; artifact `codegen`. The same steps as the codegen of the `install` job in `mcf-build.yml` | frontend-ci-components graphql-codegen |
| [`helm-chart.yml`](.github/workflows/helm-chart.yml) | PR: `check` (version bump, CHANGELOG, lint, helm-unittest); main: `release` → ECR `helm-charts/<name>` ([`push-helm-chart-to-aws-ecr`](push-helm-chart-to-aws-ecr/action.yml), cosign-signed and verified after the push) | system/components/helm-ci helm-merge-request + helm-release |
| [`gitleaks.yml`](.github/workflows/gitleaks.yml) | PR only: one job `gitleaks`, [`gitleaks/gitleaks-action`](https://github.com/gitleaks/gitleaks-action) on the PR's commits with the central `gitleaks/gitleaks.toml`; needs the `GITLEAKS_LICENSE` org secret; each repo calls it from its own `.github/workflows/gitleaks.yml` (no shared workflow here runs it) | — |
| [`pr-checks.yml`](.github/workflows/pr-checks.yml) | PR only: check-encoding of the changed files, `kustomize build` of a changed overlays tree, kyverno-cli over the images that change adds (warning only until `image-signatures-enforce`), and the `networkPolicy` values gate of a changed tree (`helm template` of the pinned commons-app / postgres chart from ECR, kubeconform against the Cilium CRD schema, fluxcd's netpol-broad-gate; the key only in `overlays/omicron`; [`pr-checks/check-network-policy.py`](pr-checks/check-network-policy.py), tests `scripts/test-network-policy-gate.sh`); its `gitleaks` input is deprecated and ignored | — |

Warehouse refresh: GitHub org webhook → Kargo cluster receiver, see fluxcd `iota/us-iota-lw-kube-infra/kargo/webhook-receivers.yaml`; Warehouses still poll every 5 min as fallback.

### mcf-build: tests/ and functional tests

The port of mcf@3 `unified-tests-types`, `unified-tests-lint` and `functional-tests/run`
([issues-maestra#1573](https://github.com/maestra-io/issues-maestra/issues/1573)). Nothing
changes in the MCF repo: the jobs switch on by files.

- **Two layouts of `tests/`.** `tests/package-lock.json` present: `tests/` is its own npm
  project, `tests-install` runs `npm ci` there (nora `.npmrc`, OIDC token and lockfile
  rewrite as `install`) and caches `tests/node_modules` under
  `mcf-tests-node-modules-<os>-<arch>-<node>-<hash of tests/package-lock.json>`. No
  `tests/package-lock.json`: `tests` is an npm workspace of the root (`"workspaces": ["tests"]`),
  the root `npm ci` installs it, and the root cache holds `node_modules` and
  `tests/node_modules` (the version-clashing packages stay there); `npm ci` in `tests/`
  would fail without a lockfile.
- **`tests-checks`** (`tests/package.json`): `npm run check-types` and `check-scripts` in
  `tests/`, each in its own log group, fails the run and holds the `image` (no release).
- **`functional`** (`tests/functional/playwright.config.ts`; on pull requests and pushes, not on
  `renovate/*` or `LocalizationPull`): the `static` artifact of `build` (source maps
  removed) is unpacked to an empty `site/` and served by `http-server@14.1.1` (from nora,
  cached per repo after the first install) on `http://localhost:8080`, the port the tests expect; then
  `BASE_URL=http://localhost:8080 RETRIES=2 WORKERS=<functional-workers> npm run functional:ci`
  in `tests/`. The backend is mocked by the tests: no secrets, no stand.
- **Browser.** No browser download ([issues-maestra#1649](https://github.com/maestra-io/issues-maestra/issues/1649)):
  `npm run functional:ci` runs inside `PLAYWRIGHT_IMAGE` (`packages.maestra.io/mcr/playwright`,
  MCR's Playwright image through nora) with the tag `v<X>-noble`, `<X>` the `@playwright/test`
  of `tests/`, resolved to its index digest per run (logged as `Playwright browsers: <tag> =
  <image>@sha256:…`) and run by that digest, so the browsers are the ones of the tests'
  Playwright. The job's Node (`node-version`) is mounted in, `--network host` reaches
  http-server on `:8080`, `--user` is the runner's; nora docker credentials come from the
  `nora-cred-helper` block. A Playwright release nora still quarantines (3 days) fails the
  job with `nora does not serve …`. frontend-playwright prefers `/usr/bin/google-chrome`,
  which the image does not have, so the tests run in the image's Chromium.
  `functional-system-chrome: true` (default `false`, opt-in per repo) runs the tests on the
  runner in its Chrome instead, no image pull; off the runner image's Chrome it falls back to
  the image.
- **Blocking.** `functional-required` defaults to `true`: a red run fails the workflow and
  `pr gate`, and the `image` (and so `release`, `bake`) does not run. A repo opts out with
  `functional-required: false`: the job gets `continue-on-error`, a red run shows ❌ and
  "not blocking: functional-required is false" in its step summary but holds nothing.
- **Results.** Step summary from the JUnit (tests, passed, failed = `failures` + `errors`,
  flaky, skipped, duration, every failed test by name). Artifacts:
  `functional-junit-<attempt>` (`tests/functional/test-results/results.xml`, 7 days, always)
  and, on failure, `functional-test-results-<attempt>` (`tests/functional/test-results`
  with traces and screenshots, 3 days; traces are on for every test, 19–86 MB). The
  JUnit also goes to [test-results-ingest](#test-results-ingest-flaky-test-telemetry).

`scripts/test-functional.sh` (selftest) runs the detection, the server wait, the
`docker run` and the summary blocks of the workflow.

### mcf-build: e2e stand and e2e tests

The port of mcf@3 e2e ([issues-maestra#1573](https://github.com/maestra-io/issues-maestra/issues/1573)):
the Playwright tests of `tests/e2e/` (`@mindbox-cloud/frontend-playwright`) run on pull
requests against a stand of the PR. Both jobs need `tests/e2e/playwright.config.ts` (with
`tests/package.json`; not on `renovate/*` or `LocalizationPull`); the stand is published
unconditionally, the tests run only with input `e2e`.

- **`e2e-stand`** (pull requests from this repository, the conditions of `hot-test` without
  its input): a second call of
  [`hot-test-publish.yml`](.github/workflows/hot-test-publish.yml) with `stand-prefix: e2e`, so the
  PR's own entry (its `CDN_URL` is the stand host) goes to
  `admin-hot-test-static-omicron-wnam/e2e-<repo>-pr-<N>/` and the stand is
  `https://e2e-<repo>-pr-<N>.testing-env.omicron.maestra.io`, environment `e2e`. fluxcd renders
  its routes like the hot-test ones but sends the API to the e2e tenant (`ci-gate.omicron.maestra.io`);
  fluxcd registers an e2e provider for every MCF with `tests/e2e/` (except the legacy `frontend`).
- **No route → skipped.** When fluxcd has no e2e provider for the repo, `e2e-stand` publishes the
  static, shows ⚠️ "not registered in fluxcd for e2e stands" and outputs `route: false`; `e2e` is
  then skipped, it never fails on the login.
- **`e2e`** (input `e2e`, default `true`: every repo with `tests/e2e/` runs them, `e2e: false` in
  `pr.yml` opts out; `e2e: true` is a no-op left from the opt-in period;
  `pool=build`, 60 min): the root and `tests/` caches as `functional`, then `npm run e2e:ci`
  in `tests/` inside `PLAYWRIGHT_IMAGE` by digest, as `functional` (no browser download), with
  `CI=true`, `BASE_URL=https://e2e-<repo>-pr-<N>.testing-env.omicron.maestra.io`,
  `ADMINSITE_USERNAME`, `ADMINSITE_PASSWORD`, `TEST_ENVIRONMENT=pull-request`, `RETRIES=2`,
  `WORKERS=<e2e-workers>` (default 4), each passed to the container by name (`-e NAME`).
- **Credentials.** `hashicorp/vault-action` against the central Vault (`jwt-github`), role
  `e2e-vault-role` (default `ci-gate-e2e`), keys `ADMINSITE_USERNAME` and
  `ADMINSITE_PASSWORD` of the KV v2 secret `e2e-vault-secret` (default
  `gitlab/data/ci-e2e/ci-gate`, i.e. `vault kv get gitlab/ci-e2e/ci-gate`). The values
  are masked step outputs passed to the test step only (`exportEnv: false`), never printed. The
  role must be bound to `mcf-build.yml` in its `job_workflow_ref`.
- **Advisory.** `continue-on-error: ${{ !inputs.e2e-required }}`, default `false`. `e2e` is not
  in the `needs` of `image` or `release`: the run takes 20–50 min, and `e2e-required` only makes
  a red run fail the workflow; gating the release on it is a later change.
- **Results.** Step summary from `tests/e2e/test-results/results.xml` (stand URL, tests, passed,
  failed, flaky, skipped, duration, failed tests by name; no JUnit after a red run is ❌).
  Artifacts `e2e-junit-<attempt>` (7 days, always) and, on failure, `e2e-test-results-<attempt>`
  (`tests/e2e/test-results` with traces, 3 days). The JUnit also goes to
  [test-results-ingest](#test-results-ingest-flaky-test-telemetry).

### mcf-build: e2e image

The same tests run after every promotion to omicron ([issues-maestra#1573](https://github.com/maestra-io/issues-maestra/issues/1573)):
`e2e-image` bakes them into `<image>-e2e:<release>` next to `<image>-with-deps`, and chart
`mcf-e2e` (maestra-io/helm-charts) runs it as a Job after the MCF's upload, against the
admin of ci-gate.

- **When.** On a release (`push` to the default branch), after `image`, alongside `deps-image`,
  for a repo with `tests/e2e/playwright.config.ts` and `tests/package.json`. Input `e2e` does not
  apply: it only switches the pull request job off; a repo without `helm-release-e2e.yaml` in its
  `kustomization/` never runs the image.
- **Contents.** The build context is `tests/` with `tests/node_modules` from the `tests-install`
  cache; for a `tests` workspace of the root (no `tests/package-lock.json`) the root cache is
  restored and every package npm hoisted to the root `node_modules` (and its `.bin` links) is
  copied into `tests/node_modules`, those already there kept (a linked local package by its
  contents; the workspace's link to `tests/` itself is skipped). A copied package resolves its
  dependencies from `tests/node_modules` first, so a version `tests/` pins differently from the
  root wins there; a repo that hits this gives `tests/` its own lockfile. Base
  `packages.maestra.io/mcr/playwright:v<X>-noble@<digest>` (`PLAYWRIGHT_IMAGE`, MCR's image
  through nora), `<X>` the installed `@playwright/test`, the digest resolved when the Dockerfile
  is written, its global npm replaced by the npm of `DEPS_BASE` (pulled through nora; the
  npm of an older Playwright image bundles a vulnerable `tar`, 1.62.1 ships 7.5.15), `WORKDIR /tests`, user `pwuser`, `CMD ["npm","run","e2e:ci"]`; the
  `node_modules` and the sources are separate layers in the gha cache (scope `mcf-e2e-<image>`).
  Labels and the best-effort signature as `-with-deps`.
- **Release gate.** `release` waits for `e2e-image` when the repo has `tests/e2e/`: a failed bake
  holds the release; without `tests/e2e/` the skipped job holds nothing.

`scripts/test-e2e.sh` (selftest) runs the detection, summary, Playwright image (against a fake
`docker`) and e2e image Dockerfile blocks and checks the wiring of the three jobs.

[`scripts/dockerfile-from-fix.sh`](scripts/dockerfile-from-fix.sh) drops the
`cr.yandex/crp2cvbrp76d7dmfegco/` mirror prefix from `FROM` lines (idempotent);
base images then come from `mcr.microsoft.com` directly and from `docker.io`
through RunsOn's ECR pull-through cache.

[`scripts/nuget-secret-mount-fix.sh`](scripts/nuget-secret-mount-fix.sh) replaces the
GitLab-era `dotnet nuget update source private --password $(cat /run/secrets/...)`
RUN (it writes the minutes-lived OIDC token into a cached layer, replayed after it
expired) with `--mount=type=secret,id=NUGET_CREDENTIALS,env=NuGetPackageSourceCredentials_<source>`
on every `dotnet` RUN that can reach the feed (idempotent). Until then the
workflows build such a Dockerfile without the layer cache.

## Create GitHub Release (`create-github-release`)

A copy of `mindbox-cloud/github-actions/create-github-release` with the same inputs and
outputs. Every inner action is SHA-pinned, because the org SHA-pinning policy also checks the
`uses:` lines inside a composite. One change from upstream: the changelog goes into the shell
through `env:`, not by interpolation. Swap the upstream reference for this one:

```yaml
- uses: maestra-io/github-actions/create-github-release@<40-hex sha> # v1.48.0
  with:
    release-number: ${{ steps.version.outputs.release-number }}
```
