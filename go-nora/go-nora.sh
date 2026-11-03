#!/usr/bin/env bash
# Exports GOPROXY + GOAUTH for nora and writes the token output (see action.yml).
# Env: NORA_URL, NORA_AUDIENCE; RUNNER_TEMP, GITHUB_ENV, GITHUB_OUTPUT and the
# runner's ACTIONS_ID_TOKEN_REQUEST_{URL,TOKEN}.
set -euo pipefail

: "${ACTIONS_ID_TOKEN_REQUEST_URL:?no GitHub OIDC token available: the job needs permissions: id-token: write}"
url="${NORA_URL%/}"
dir="${RUNNER_TEMP}/go-nora"
mkdir -p "$dir"

# GOAUTH command: run by every `go` process before its first fetch, and again with
# the URL as argument after a 4xx (an expired token): each run mints a new token.
helper="$dir/goauth"
cat > "$helper" <<SH
#!/usr/bin/env bash
set -euo pipefail
token=\$(curl -fsS --retry 3 -H "Authorization: bearer \${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \\
  "\${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=$NORA_AUDIENCE" | jq -r .value)
[ -n "\$token" ] && [ "\$token" != null ] || { echo "go-nora: no OIDC token" >&2; exit 1; }
printf '%s/go\n\nAuthorization: Basic %s\n\n' "$url" "\$(printf 'token:%s' "\$token" | base64 | tr -d '\\n')"
SH
chmod +x "$helper"

token=$(curl -fsS --retry 3 -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${NORA_AUDIENCE}" | jq -r .value)
[ -n "$token" ] && [ "$token" != null ] || { echo "::error::go-nora: no OIDC token" >&2; exit 1; }
echo "::add-mask::$token"

{
  echo "GOPROXY=$url/go"
  echo "GOAUTH=command $helper"
} >> "$GITHUB_ENV"
echo "token=$token" >> "$GITHUB_OUTPUT"
echo "go: modules from $url/go (GOAUTH $helper)"
