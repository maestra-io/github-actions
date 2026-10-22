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
its own image under the immutable tag and skips the push instead of failing on `TAG_INVALID`:

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

### Second region

The dual-push of the ECR eu-central-1 → us-west-2 migration
([issues-maestra#1354](https://github.com/maestra-io/issues-maestra/issues/1354), phases 3–6) is
gone from `push-to-aws-ecr-repository` and `bake-oci-manifests`: us-west-2 is the only registry.
The standalone [`mirror-to-secondary-ecr`](#mirror-an-ecr-tag-to-the-secondary-region) action is
a no-op with its default inputs and is removed once the last caller drops the step.

## Bake OCI manifests artifact

Bakes a microservice's `kustomization/` tree into an OCI artifact at `${ECR_REGISTRY}/<service>-manifests:<tag>`, cosign-keyless-signs the digest, and verifies the pulled artifact contains no leftover `${APP_PACKAGE_VERSION_TO_BE_REPLACED}` placeholders. This is the GitHub-side half of the **OCI + Kargo** deploy pattern documented in [`maestra-io/fluxcd/docs/microservice-deployment.md`](https://github.com/maestra-io/fluxcd/blob/main/docs/microservice-deployment.md).

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
- `flux-version`: flux CLI version, no `v-` prefix. Default `2.8.6`.
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
## Mirror an ECR tag to the secondary region

**Deprecated, no-op with the default inputs** (us-west-2 is the only registry since phase 6 of
[issues-maestra#1354](https://github.com/maestra-io/issues-maestra/issues/1354)); callers drop the step, then the action goes.

For workflows that push to ECR with their **own** `docker push` /
`docker buildx build --push` / `docker/build-push-action` / `helm push oci://` instead of going
through `push-to-aws-ecr-repository` or `bake-oci-manifests`. One step after the push and the tag
resolves to the same digest in `eu-central-1` and `us-west-2`
([issues-maestra#1354](https://github.com/maestra-io/issues-maestra/issues/1354), rake #8).

The mirror body is the same doctrine documented in
[Second region](#second-region): reference digest from
`aws ecr describe-images` in the primary region, import **by digest** (children before the index for
a multi-arch image), wait on `describe-images` in the secondary region for real storage, `crane tag`,
assert both regions. It nowhere uses `crane copy` or `crane digest`.

The action assumes AWS credentials are **already** usable — it does not log in on its own.

A secondary repository it has to create gets the same tag immutability as
[`push-to-aws-ecr-repository`](#tag-immutability), so `crane tag` can move `latest` but not a
release tag that already points at another digest.

### Usage

`aws-actions/configure-aws-credentials` or static keys (credentials persist into the job env):

```yaml
- name: Mirror to us-west-2
  uses: maestra-io/github-actions/mirror-to-secondary-ecr@main
  with:
    repository: my-service
    tag: ${{ steps.release-number.outputs.release-number }},latest
```

Teleport Workload Identity workflows export `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` inside
a `run:` step, so those exports are gone by the next step. Point the action back at the same
on-disk JWT instead of changing the login step:

```yaml
- name: Mirror to us-west-2
  uses: maestra-io/github-actions/mirror-to-secondary-ecr@main
  with:
    repository: ${{ env.IMAGE_NAME }}
    tag: ${{ steps.release-number.outputs.release-number }},latest
    registry: ${{ env.ECR_REGISTRY }}
    awsRoleArn: ${{ env.AWS_ROLE_ARN }}
    awsWebIdentityTokenFile: /tmp/tbot-output/jwt_svid
```

### Inputs

- `repository`: comma-separated ECR repository names just pushed, e.g. `my-service` or
  `my-service,helm-charts/my-service`. **(required)**
- `tag`: comma-separated tags just pushed, e.g. `1.0.42,latest`. Every tag is mirrored for every
  repository (cross product). **(required)**
- `primaryRegion`: region the images were pushed to. Default `us-west-2` (phase 6 — eu-central-1 is
  frozen).
- `secondaryRegion`: region that receives the copy. Default `''` (no-op) since phase 6. Re-enabling
  only works as `primaryRegion: eu-central-1` + `secondaryRegion: us-west-2` — the copy is a cache
  prime + storage poll and only us-west-2 carries the registry-ROOT pull-through-cache rule.
- `registry`: primary ECR registry host. Default `''` — the calling identity's own account in
  `primaryRegion`, resolved with `aws sts get-caller-identity`.
- `awsRoleArn` / `awsWebIdentityTokenFile`: only for Teleport Workload Identity workflows, see
  above. Default `''` — credentials are taken from the job env.
- `craneVersion`: crane CLI version, no `v-` prefix. Default `0.22.0`. Downloaded into a `mktemp -d`,
  never into the workspace (a chart repo that packs its own root would ship the binary).

### Prerequisites

The identity the job runs as needs, in the secondary region: `ecr:DescribeImages`,
`ecr:DescribeRepositories`, `ecr:CreateRepository`, `ecr:SetRepositoryPolicy`, `ecr:PutImage` and
the layer/manifest read verbs — `teleport-image-push` has them from `TeleportImagePush`
([aws-infra#53](https://github.com/maestra-io/aws-infra/pull/53),
[#54](https://github.com/maestra-io/aws-infra/pull/54)) and the static registry user has them from
`AmazonEC2ContainerRegistryFullAccess`. `ecr:BatchImportUpstreamImage` (the pull-through-cache
import) comes from the `us-west-2` **registry** policy, which grants it org-wide — note that
`aws iam simulate-principal-policy` does not evaluate registry policies and will report
`implicitDeny` for it.

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

The action installs the newest gitleaks release (`GITLEAKS_VERSION: latest`). One input,
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

| workflow | does | GitLab original |
| --- | --- | --- |
| [`dotnet-service-build.yml`](.github/workflows/dotnet-service-build.yml) | `version` → `test` → `images` (matrix) → `release` → `bake` | dotnet-service-cicd-components release-template, create-release-number, docker-push-to-all, maestra-bake-oci-manifests |
| [`service-build.yml`](.github/workflows/service-build.yml) | same jobs as `dotnet-service-build.yml` for any language: `test` runs the repo's `test-command` (optional `python-version` / `node-version`) or a Dockerfile `docker-test-target`; build secrets under the Dockerfile's own ids (`build-secret-ids`) | docker-push-to-all, maestra-bake-oci-manifests, create-release-number, the repo's own GitLab test jobs |
| [`nuget-package-publish.yml`](.github/workflows/nuget-package-publish.yml) | restore, build, test, pack, `dotnet nuget push` | dotnet-nuget-cicd-components |
| [`npm-package-publish.yml`](.github/workflows/npm-package-publish.yml) | `npm ci`, lib@3 checks (`checks` input: graphql-codegen, check-types, check-scripts, check-styles, test; `--if-present`, all reported), optional PR coverage comment (`report-coverage`), `npm run release` (semantic-release); RunsOn `pool` input `small` (default) or `build` | frontend-ci-components `templates/lib` |
| [`python-package-publish.yml`](.github/workflows/python-package-publish.yml) | poetry/uv build, test, `twine upload` | — |
| [`mcf-build.yml`](.github/workflows/mcf-build.yml) | micro-frontends: `install` (node_modules cached by lockfile hash, `npm ci` only on a miss) → `codegen` (GitHub OIDC → auth-jwt omega JWT) → `checks`, `test`, `build` → `image` (rclone + `<static-prefix>`, default `v2_static/<mcf>`; `static-prefix: v2_static/core` and `manifest: core` for the admin shell frontend-core-v2) → `release` → `bake`, `sourcemaps` (Datadog US3, key from the central Vault); the bucket upload runs at promotion from the MCF's own `kustomization/`. With `tests/`: `tests-install`, `tests-checks` and, after `build`, `functional` (Playwright against the built static, [below](#mcf-build-tests-and-functional-tests)), and on pull requests `e2e-stand` → `e2e` (Playwright against the PR's e2e stand, input `e2e`, [below](#mcf-build-e2e-stand-and-e2e-tests)). On pull requests `pr gate` is the check a branch ruleset requires (`build / pr gate`): red when a PR job failed or was cancelled; `functional` and `e2e` count only with `functional-required` / `e2e-required` | frontend-ci-components `templates/mcf` (mcf@3) |
| [`hot-test-publish.yml`](.github/workflows/hot-test-publish.yml) | hot-test stand of a pull request ([issues-maestra#1574](https://github.com/maestra-io/issues-maestra/issues/1574)): the PR's static artifact + an entry from `frontend-entry-static-builder --single-run` with the PR's manifest → R2 `admin-hot-test-static-omicron/hot-test-<repo>-pr-<N>/` (Teleport GitHub join from the PR → Vault omicron → 10-minute editor keys); the stand URL `https://hot-test-<repo>-pr-<N>.testing-env.omicron.maestra.io` is in the PR as a deployment of environment `hot-test` and in the job's step summary. Called by `mcf-build.yml` on pull_request (input `hot-test`) and by the legacy admin monorepo's own `pr.yml` (`static-prefix: public`, `manifest: none`: its dist goes to `public/` of the PR folder, the entry is the released shell, and the backend links `/public/...` from the stand's host on `X-Testing-Frontend`); the routes come from the builder's chart per open PR. Input `stand-prefix` (default `hot-test`) is the first word of the stand name, environment and bucket folder: `mcf-build.yml` calls the workflow a second time with `e2e` for the [e2e stand](#mcf-build-e2e-stand-and-e2e-tests). Outputs: `url`, and `route` (`true` once the stand's `/entry/index.html` answered 200, `false` when the static is published but fluxcd has no route for it: ⚠️, the job stays green). Inputs: `bucket` (stands' bucket, write), `base-static-url` (release static the entry is built from), `hot-test-domain`, `static-prefix` (the PR's own folder, default `v2_static/<mcf>`, the module federation folder; a repo whose files live elsewhere — `frontend` `public`, `frontend-core-v2` `v2_static/core` — sets the same path as `staticPrefix` in its fluxcd registration, which the stand's route sends to the PR folder), `manifest` (`mcf`, `core` for frontend-core-v2: its `manifest.json` and `build-info.json` become the builder's core overrides, or `none`); the tenant and the cluster's copies of these addresses live only in fluxcd (component `base/microfrontend/hot-test`). After the route is up the job compares every release manifest the entry was built from (`v2_static/core/manifest.json` and `v2_static/<mcf>/mf-manifest.json` of each MCF in its `entry/mcf-manifests.json` but those under `static-prefix`) through the stand with the ones under `base-static-url`: another release bucket in the cluster's `baseStaticDomain` (first differing path in the summary) or a non-200 from the stand is ❌ and fails the job | frontend-ci-components mcf@3 hot-test environments |
| [`frontend-codegen.yml`](.github/workflows/frontend-codegen.yml) | one job `codegen` for a frontend with its own pipeline (maestra-io/frontend): restores the `install` job's `node_modules` cache, GitHub OIDC → auth-jwt omega JWT (client `github-frontend-graphql-schema`, bound to this workflow at `@refs/heads/main`) → `npm run graphql-codegen`; artifact `codegen`. The same job as `codegen` in `mcf-build.yml` | frontend-ci-components graphql-codegen |
| [`helm-chart.yml`](.github/workflows/helm-chart.yml) | PR: `check` (version bump, CHANGELOG, lint, helm-unittest); main: `release` → ECR `helm-charts/<name>` ([`push-helm-chart-to-aws-ecr`](push-helm-chart-to-aws-ecr/action.yml)) | system/components/helm-ci helm-merge-request + helm-release |
| [`gitleaks.yml`](.github/workflows/gitleaks.yml) | PR only: one job `gitleaks`, [`gitleaks/gitleaks-action`](https://github.com/gitleaks/gitleaks-action) on the PR's commits with the central `gitleaks/gitleaks.toml`; needs the `GITLEAKS_LICENSE` org secret; each repo calls it from its own `.github/workflows/gitleaks.yml` (no shared workflow here runs it) | — |
| [`pr-checks.yml`](.github/workflows/pr-checks.yml) | PR only: check-encoding of the changed files and `kustomize build` of a changed overlays tree; its `gitleaks` input is deprecated and ignored | — |

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
  removed) is unpacked to an empty `site/` and served by `http-server@14.1.1` (installed
  from nora) on `http://localhost:8080`, the port the tests expect; then
  `BASE_URL=http://localhost:8080 RETRIES=2 WORKERS=<functional-workers> npm run functional:ci`
  in `tests/`. The backend is mocked by the tests: no secrets, no stand.
- **Browser.** `npx playwright install --with-deps chromium` from `tests/`, so it is the
  Chromium of the Playwright the tests resolve; `~/.cache/ms-playwright` is cached by that
  version. frontend-playwright prefers `/usr/bin/google-chrome` with `--no-sandbox`
  when the file exists, so on a runner image with Chrome the tests run in that Chrome.
- **Advisory first.** The job has `continue-on-error: ${{ !inputs.functional-required }}`:
  a red run shows ❌ and "not blocking: functional-required is false" in its step
  summary but does not fail the workflow or hold the release. A repo opts in to blocking with
  `functional-required: true`: a red run then fails the workflow and the `image` (and so
  `release`, `bake`) does not run. The default turns `true` once the MCFs are green.
- **Results.** Step summary from the JUnit (tests, passed, failed = `failures` + `errors`,
  flaky, skipped, duration, every failed test by name). Artifacts:
  `functional-junit-<attempt>` (`tests/functional/test-results/results.xml`, 7 days, always)
  and, on failure, `functional-test-results-<attempt>` (`tests/functional/test-results`
  with traces and screenshots, 3 days; traces are on for every test, 19–86 MB). The
  JUnit also goes to [test-results-ingest](#test-results-ingest-flaky-test-telemetry).

`scripts/test-functional.sh` (selftest) runs the detection, the server wait and the
summary blocks of the workflow.

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
  `admin-hot-test-static-omicron/e2e-<repo>-pr-<N>/` and the stand is
  `https://e2e-<repo>-pr-<N>.testing-env.omicron.maestra.io`, environment `e2e`. fluxcd renders
  its routes like the hot-test ones but sends the API to the e2e tenant (`autotests-eu.maestra.io`);
  fluxcd registers an e2e provider for every MCF with `tests/e2e/` (except the legacy `frontend`).
- **No route → skipped.** When fluxcd has no e2e provider for the repo, `e2e-stand` publishes the
  static, shows ⚠️ "not registered in fluxcd for e2e stands" and outputs `route: false`; `e2e` is
  then skipped, it never fails on the login.
- **`e2e`** (input `e2e`, default `false`: the repo turns its tests on with `e2e: true` in its
  `pr.yml`, and that PR is also its first e2e run; the input goes away once every repo is on;
  `pool=build`, 60 min): the root and `tests/` caches as `functional`, Chromium of the
  tests' Playwright, then `npm run e2e:ci` in `tests/` with `CI=true`,
  `BASE_URL=https://e2e-<repo>-pr-<N>.testing-env.omicron.maestra.io`, `ADMINSITE_USERNAME`,
  `ADMINSITE_PASSWORD`, `TEST_ENVIRONMENT=pull-request`, `RETRIES=2`, `WORKERS=<e2e-workers>`
  (default 4).
- **Credentials.** `hashicorp/vault-action` against the central Vault (`jwt-github`), role
  `e2e-vault-role` (default `ci-e2e-autotests-eu`), keys `ADMINSITE_USERNAME` and
  `ADMINSITE_PASSWORD` of the KV v2 secret `e2e-vault-secret` (default
  `gitlab/data/ci-e2e/autotests-eu`, i.e. `vault kv get gitlab/ci-e2e/autotests-eu`). The values
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

`scripts/test-e2e.sh` (selftest) runs the detection and summary blocks and checks the wiring of
both jobs.

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
