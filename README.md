# GitHub Actions

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