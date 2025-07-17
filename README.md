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