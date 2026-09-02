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

**Reusable workflows and composite actions** — pin the immutable sha and name the tag in a trailing
comment. That is the format Renovate writes and reads, so it bumps the sha and the comment together
and can never propose the two out of step:

```yaml
uses: maestra-io/github-actions/.github/workflows/terraform-run.yml@4400cd4787fea8b4353aad7d90621d573af8ddc9 # v1.1.7
```

If you would rather not review a Renovate PR per patch, `@v1` is also valid — a moving alias that
only goes forward inside major 1. You give up the audit trail of *which* revision ran, so prefer the
sha form for anything that touches production.

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
`v1`, so consumers on `@v1` stay where they are until they migrate. Consumers pinned to a sha are
unaffected until their Renovate PR is reviewed. Mark a change breaking whenever an input is removed
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
- name: Push to ECR
  uses: ./push-to-aws-ecr-repository
  with:
    awsAccessKey: ${{ secrets.AWS_ACCESS_KEY_ID }}
    awsSecretKey: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    awsRegion: us-east-1
    awsOrganizationId: o-example123456
    repositories: 'repo1,repo2,repo3'
    localTag: 'latest'
    targetTag: 'v1.0.0'
```

### Inputs

- `awsAccessKey`: AWS Access Key ID (required)
- `awsSecretKey`: AWS Secret Access Key (required)
- `awsRegion`: AWS Region (required). Since phase 6 of the ECR migration
  ([issues-maestra#1354](https://github.com/maestra-io/issues-maestra/issues/1354)) a stale
  `eu-central-1` is normalised to `us-west-2` with a workflow warning — the EU registry is frozen
  and read by nothing.
- `awsOrganizationId`: AWS Organization ID for ECR policy (required)
- `repositories`: Comma-separated list of repository names (required)
- `localTag`: Tag of locally built images that must be pre-built (required)
- `targetTag`: Target tag for all ECR repositories (required)
- `awsRegionSecondary`: second ECR region every pushed image is mirrored to. Default `''` (mirror off) since phase 6 — `us-west-2` is the only push target. See [Dual-push to a second region](#dual-push-to-a-second-region) for the one direction a mirror can be re-enabled in.
- `craneVersion`: crane CLI version used by the mirror step, no `v-` prefix. Default `0.22.0`.

### Prerequisites

Before running this action, ensure that:
1. Docker images are built locally with the specified `localTag`
2. Images should be tagged as `local/{repository-name}:{localTag}`
3. AWS credentials have appropriate ECR permissions

### Example

If you have three services: `api`, `frontend`, and `worker`, you would:

1. Build your images locally:
   ```bash
   docker build -t local/api:latest ./api
   docker build -t local/frontend:latest ./frontend
   docker build -t local/worker:latest ./worker
   ```

2. Use the action:
   ```yaml
   - uses: ./push-to-aws-ecr-repository
     with:
       awsAccessKey: ${{ secrets.AWS_ACCESS_KEY_ID }}
       awsSecretKey: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
       awsRegion: us-east-1
       awsOrganizationId: o-example123456
       repositories: 'api,frontend,worker'
       localTag: 'latest'
       targetTag: 'v1.0.0'
   ```

This will push all three images to their respective ECR repositories with the `v1.0.0` tag.

### Dual-push to a second region

Both `push-to-aws-ecr-repository` and `bake-oci-manifests` mirror everything they push to
`us-west-2` — phase 3 of the ECR `eu-central-1` → `us-west-2` migration
([issues-maestra#1354](https://github.com/maestra-io/issues-maestra/issues/1354)). Consumers need
no change: they pin `@main`, and the mirror is on by default.

The mirror never re-pushes. It reads the digest the **primary** region *stores* for the tag
(`aws ecr describe-images` — the repository's own record), triggers the import in the secondary
region **by digest**, waits until `describe-images` there confirms real storage, writes the tag with
`crane tag`, and asserts the tag resolves to the same digest in both regions.

That shape is not stylistic. `us-west-2` carries a registry-root pull-through-cache rule onto
`eu-central-1`, so a registry *read* against the US host answers through the cache for content the
US repository does not store: `crane copy` sees "destination already has it" and no-ops over a stale
tag, and `crane digest` confirms content the job never wrote — while pinning that tag in the cache
for 24 h. `crane tag` is the only primitive that rewrites the storage record unconditionally, and
`describe-images` is the only honest "what is actually stored" question.

Multi-arch images have their child manifests imported before the index — an index whose children
have not landed fails with `MANIFEST_BLOB_UNKNOWN`. Single-manifest images have no children and skip
that loop.

**The off-switch is the default since phase 6**: `awsRegionSecondary` / `aws-region-secondary`
default to `''`, the mirror steps are skipped entirely, and the actions push to `us-west-2` only —
eu-central-1 is frozen. If a mirror ever needs to come back, the ONLY working direction is
`awsRegion: eu-central-1` + `awsRegionSecondary: us-west-2` (for the bake action additionally the
two matching registry-host inputs): the mirror is a cache prime + storage poll, and only us-west-2
carries the registry-ROOT pull-through-cache rule. The inverse assignment would poll `describe-images`
for 180 s per digest and fail the job.

Workflows that push with their **own** `docker push` / `docker buildx build --push` /
`docker/build-push-action` / `helm push` instead of going through either action get the same
guarantee from [`mirror-to-secondary-ecr`](#mirror-an-ecr-tag-to-the-secondary-region) — one step
after their push.

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
- `aws-region-secondary`: second ECR region the baked artifact is mirrored to. Default `''` (mirror off) since phase 6. See [Dual-push to a second region](#dual-push-to-a-second-region) — re-enabling only works as `aws-region: eu-central-1` + `aws-region-secondary: us-west-2` (plus the matching two registry hosts), never the inverse.
- `ecr-registry-secondary`: ECR registry host in that region. Default `515260921971.dkr.ecr.us-west-2.amazonaws.com`.
- `crane-version`: crane CLI version used by the mirror step, no `v-` prefix. Default `0.22.0`.
- `teleport-fqdn`: Teleport proxy. Default `teleport.maestra.io:443`.
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

For workflows that push to ECR with their **own** `docker push` /
`docker buildx build --push` / `docker/build-push-action` / `helm push oci://` instead of going
through `push-to-aws-ecr-repository` or `bake-oci-manifests`. One step after the push and the tag
resolves to the same digest in `eu-central-1` and `us-west-2`
([issues-maestra#1354](https://github.com/maestra-io/issues-maestra/issues/1354), rake #8).

The mirror body is the same doctrine documented in
[Dual-push to a second region](#dual-push-to-a-second-region): reference digest from
`aws ecr describe-images` in the primary region, import **by digest** (children before the index for
a multi-arch image), wait on `describe-images` in the secondary region for real storage, `crane tag`,
assert both regions. It nowhere uses `crane copy` or `crane digest`.

The action assumes AWS credentials are **already** usable — it does not log in on its own.

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
