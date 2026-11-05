#!/usr/bin/env bash
# Exports uv credentials for nora and writes the token output (see action.yml).
# Env: NORA_URL, NORA_AUDIENCE; RUNNER_TEMP, GITHUB_ENV, GITHUB_PATH, GITHUB_OUTPUT
# and the runner's ACTIONS_ID_TOKEN_REQUEST_{URL,TOKEN}.
set -euo pipefail

: "${ACTIONS_ID_TOKEN_REQUEST_URL:?no GitHub OIDC token available: the job needs permissions: id-token: write}"
url="${NORA_URL%/}"
dir="${RUNNER_TEMP}/uv-nora/bin"
mkdir -p "$dir"

# uv --keyring-provider subprocess runs `keyring get <index url> <username>` and
# reads the password from stdout: each uv process gets a newly minted token.
# Only for nora's own URLs; anything else gets nothing (exit 1).
cat > "$dir/keyring" <<SH
#!/usr/bin/env bash
set -euo pipefail
[ "\${1:-}" = get ] || exit 1
case "\${2:-}" in "$url"/*|"$url") ;; *) exit 1 ;; esac
token=\$(curl -fsS --retry 3 -H "Authorization: bearer \${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \\
  "\${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=$NORA_AUDIENCE" | jq -r .value)
[ -n "\$token" ] && [ "\$token" != null ] || { echo "uv-nora: no OIDC token" >&2; exit 1; }
printf '%s\n' "\$token"
SH
chmod +x "$dir/keyring"

token=$(curl -fsS --retry 3 -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${NORA_AUDIENCE}" | jq -r .value)
[ -n "$token" ] && [ "$token" != null ] || { echo "::error::uv-nora: no OIDC token" >&2; exit 1; }
echo "::add-mask::$token"

echo "$dir" >> "$GITHUB_PATH"
{
  echo "UV_KEYRING_PROVIDER=subprocess"
  echo "UV_INDEX_MAESTRA_USERNAME=token"
} >> "$GITHUB_ENV"
echo "token=$token" >> "$GITHUB_OUTPUT"
echo "uv: index maestra = $url/simple/ (keyring helper $dir/keyring)"
