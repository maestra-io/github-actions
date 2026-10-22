#!/usr/bin/env bash
# Writes the Terraform CLI config and credentials helper for nora (see action.yml).
# Env: NORA_URL, NORA_AUDIENCE, FS_MIRROR_PATH, FS_MIRROR_INCLUDE; RUNNER_TEMP,
# GITHUB_ENV, HOME and the runner's ACTIONS_ID_TOKEN_REQUEST_{URL,TOKEN}.
set -euo pipefail

: "${ACTIONS_ID_TOKEN_REQUEST_URL:?no GitHub OIDC token available: the job needs permissions: id-token: write}"
url="${NORA_URL%/}"
host="${url#https://}"
host="${host%%/*}"
dir="${RUNNER_TEMP}/terraform-nora"
mkdir -p "$dir" "$HOME/.terraform.d/plugins"

# Terraform looks credentials helpers up as terraform-credentials-<name> in its
# plugin directories. `get <host>` prints {"token": ...}; any other host gets {}.
helper="$HOME/.terraform.d/plugins/terraform-credentials-nora"
cat > "$helper" <<SH
#!/usr/bin/env bash
set -euo pipefail
[ "\${1:-}" = get ] || { echo "terraform-credentials-nora: only 'get' is supported" >&2; exit 1; }
if [ "\${2:-}" != "$host" ]; then echo '{}'; exit 0; fi
token=\$(curl -fsS --retry 3 -H "Authorization: bearer \${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \\
  "\${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=$NORA_AUDIENCE" | jq -r .value)
[ -n "\$token" ] && [ "\$token" != null ] || { echo "terraform-credentials-nora: no OIDC token" >&2; exit 1; }
jq -cn --arg t "\$token" '{token: \$t}'
SH
chmod +x "$helper"

hcl_list() { # "a, b" -> "a", "b"
  local out="" p
  IFS=',' read -ra parts <<<"$1"
  for p in "${parts[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    [ -n "$p" ] && out+="${out:+, }\"$p\""
  done
  printf '%s' "$out"
}

config="$dir/terraform.tfrc"
{
  # setup-terraform's credentials (cli_config_credentials_token) live in ~/.terraformrc,
  # which TF_CLI_CONFIG_FILE replaces.
  if [ -s "$HOME/.terraformrc" ]; then
    if grep -q provider_installation "$HOME/.terraformrc"; then
      echo "::error::~/.terraformrc already has provider_installation; merge it into this action's inputs" >&2
      exit 1
    fi
    cat "$HOME/.terraformrc"
    echo
  fi
  echo 'provider_installation {'
  if [ -n "$FS_MIRROR_PATH" ]; then
    fs_include=$(hcl_list "$FS_MIRROR_INCLUDE")
    [ -n "$fs_include" ] || { echo "::error::fs-mirror-path needs fs-mirror-include" >&2; exit 1; }
    printf '  filesystem_mirror {\n    path    = "%s"\n    include = [%s]\n  }\n' "$FS_MIRROR_PATH" "$fs_include"
    printf '  network_mirror {\n    url     = "%s/terraform/"\n    include = ["registry.terraform.io/*/*"]\n    exclude = [%s]\n  }\n' "$url" "$fs_include"
  else
    printf '  network_mirror {\n    url     = "%s/terraform/"\n    include = ["registry.terraform.io/*/*"]\n  }\n' "$url"
  fi
  printf '  direct {\n    exclude = ["registry.terraform.io/*/*"]\n  }\n}\n\ncredentials_helper "nora" {}\n'
} > "$config"

echo "TF_CLI_CONFIG_FILE=$config" >> "$GITHUB_ENV"
echo "terraform: registry.terraform.io providers from $url/terraform/ (config $config)"
