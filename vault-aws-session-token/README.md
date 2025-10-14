# Vault AWS Session Token Action

A reusable GitHub Action that authenticates to HashiCorp Vault using JWT (GitHub OIDC) and retrieves temporary AWS session token credentials from Vault's AWS secrets engine.

## Features

- 🔐 Authenticates to Vault using GitHub OIDC tokens
- ☁️ Retrieves AWS session token credentials (access key, secret key, session token)
- ⏱️ Supports custom TTL for credentials
- 🔒 Automatically masks sensitive values in logs
- 📦 Single API call to Vault's AWS secrets engine

## Prerequisites

- Vault server with JWT authentication configured for GitHub OIDC
- AWS secrets engine configured in Vault with appropriate roles
- GitHub repository with `id-token: write` permission

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `vault-addr` | Vault server address | No | `https://vault.mindbox.cloud` |
| `role-name` | AWS role name in Vault | Yes | - |
| `vault-jwt-path` | Vault JWT authentication mount path | Yes | - |
| `vault-jwt-role` | Vault JWT role name | Yes | - |
| `ttl` | TTL for AWS credentials (e.g., `15m`) | No | Role default |

## Outputs

| Output | Description |
|--------|-------------|
| `aws-access-key-id` | AWS Access Key ID |
| `aws-secret-access-key` | AWS Secret Access Key |
| `aws-session-token` | AWS Session Token |
| `lease-id` | Vault lease ID for the credentials |

## Usage

### Basic Example

```yaml
jobs:
  terraform:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write  # Required for OIDC
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Get AWS Credentials from Vault
        id: aws-creds
        uses: ./github-actions/vault-aws-session-token
        with:
          role-name: secrets-s3-secrets-terraform-state-bucket-editor
          vault-jwt-path: jwt-github
          vault-jwt-role: grafana-oncall-github-ci

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3

      - name: Terraform Init
        run: |
          terraform init \
            -backend-config="access_key=${{ steps.aws-creds.outputs.aws-access-key-id }}" \
            -backend-config="secret_key=${{ steps.aws-creds.outputs.aws-secret-access-key }}" \
            -backend-config="token=${{ steps.aws-creds.outputs.aws-session-token }}"
```

### With Custom TTL

```yaml
- name: Get AWS Credentials from Vault
  id: aws-creds
  uses: ./github-actions/vault-aws-session-token
  with:
    role-name: my-aws-role
    vault-jwt-path: jwt-github
    vault-jwt-role: my-github-role
    ttl: 30m  # 30 minutes
```

### With Custom Vault Address

```yaml
- name: Get AWS Credentials from Vault
  id: aws-creds
  uses: ./github-actions/vault-aws-session-token
  with:
    vault-addr: https://vault.example.com
    role-name: my-aws-role
    vault-jwt-path: jwt-github
    vault-jwt-role: my-github-role
```

### Using as Environment Variables

If you need to set the credentials as environment variables for subsequent steps:

```yaml
- name: Get AWS Credentials from Vault
  id: aws-creds
  uses: ./github-actions/vault-aws-session-token
  with:
    role-name: secrets-s3-secrets-terraform-state-bucket-editor
    vault-jwt-path: jwt-github
    vault-jwt-role: grafana-oncall-github-ci

- name: Set AWS Credentials as Environment Variables
  run: |
    echo "AWS_ACCESS_KEY_ID=${{ steps.aws-creds.outputs.aws-access-key-id }}" >> $GITHUB_ENV
    echo "AWS_SECRET_ACCESS_KEY=${{ steps.aws-creds.outputs.aws-secret-access-key }}" >> $GITHUB_ENV
    echo "AWS_SESSION_TOKEN=${{ steps.aws-creds.outputs.aws-session-token }}" >> $GITHUB_ENV

- name: Use AWS CLI
  run: aws s3 ls
```

## Security Considerations

- All sensitive values (tokens, keys) are automatically masked in GitHub Actions logs
- Credentials are only valid for the specified TTL (default from Vault role)
- Session tokens provide temporary, limited-scope access
- Credentials are not stored; they're generated fresh for each workflow run

## Vault Configuration

### JWT Auth Method

Your Vault server should have JWT authentication configured:

```hcl
vault auth enable -path=jwt-github jwt

vault write auth/jwt-github/config \
  bound_issuer="https://token.actions.githubusercontent.com" \
  oidc_discovery_url="https://token.actions.githubusercontent.com"

vault write auth/jwt-github/role/grafana-oncall-github-ci \
  role_type="jwt" \
  bound_audiences="https://github.com/your-org" \
  bound_claims='{"repository":"your-org/your-repo"}' \
  user_claim="actor" \
  policies="github-ci-policy" \
  ttl=1h
```

### AWS Secrets Engine

Configure the AWS secrets engine with a role:

```hcl
vault secrets enable -path=aws aws

vault write aws/config/root \
  access_key=YOUR_AWS_ACCESS_KEY \
  secret_key=YOUR_AWS_SECRET_KEY \
  region=us-east-1

vault write aws/roles/secrets-s3-secrets-terraform-state-bucket-editor \
  credential_type=assumed_role \
  role_arns=arn:aws:iam::ACCOUNT_ID:role/your-role \
  default_sts_ttl=900  # 15 minutes
```

## Troubleshooting

### Authentication Failed
- Verify `id-token: write` permission is set in your workflow
- Check that the JWT role in Vault allows your repository
- Ensure the Vault address is correct

### Failed to Retrieve Credentials
- Verify the AWS role name exists in Vault
- Check that your JWT role has permission to read from the AWS secrets engine path
- Ensure the AWS secrets engine is properly configured

## License

This action is part of the internal GitHub Actions collection.
