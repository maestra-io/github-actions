# GitHub Actions

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
- `awsRegion`: AWS Region (required)
- `awsOrganizationId`: AWS Organization ID for ECR policy (required)
- `repositories`: Comma-separated list of repository names (required)
- `localTag`: Tag of locally built images that must be pre-built (required)
- `targetTag`: Target tag for all ECR repositories (required)

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

### Inputs

- `service`: kebab-case service name. Derives `TELEPORT_TOKEN` (`image-push-github-actions-<service>`) and `IMAGE_MANIFESTS` (`<service>-manifests`). **(required)**
- `images`: comma-separated list of image basenames the action will verify exist in ECR before baking. If any is missing, the bake fails. **(required)**
- `flux-version`: flux CLI version, no `v-` prefix. Default `2.8.6`.
- `aws-region`: ECR region. Default `eu-central-1`.
- `ecr-registry`: ECR registry host. Default `515260921971.dkr.ecr.eu-central-1.amazonaws.com`.
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