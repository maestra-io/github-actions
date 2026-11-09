#!/usr/bin/env bash
# Exports GOPROXY + GOAUTH for nora and writes the token output (see action.yml).
# Env: NORA_URL, NORA_AUDIENCE; RUNNER_TEMP, GITHUB_ENV, GITHUB_OUTPUT and the
# runner's ACTIONS_ID_TOKEN_REQUEST_{URL,TOKEN}.
set -euo pipefail

: "${ACTIONS_ID_TOKEN_REQUEST_URL:?no GitHub OIDC token available: the job needs permissions: id-token: write}"
url="${NORA_URL%/}"
dir="${RUNNER_TEMP}/go-nora"
mkdir -p "$dir"

# GOAUTH helper (GOAUTH holds its path; `command` in `go help goauth` is a placeholder):
# run by every `go` process before its first fetch, and again with
# the URL as argument after a 4xx (an expired token): each run mints a new token.
# Its URL line is the origin, not $url/go: Go 1.24 looks a credential up by the full
# request URL, then by the bare host only (cmd/go loadCredential, fixed in 1.25), so a
# /go prefix never matched and every fetch went out without the header (401).
rest="${url#*://}"
origin="${url%%://*}://${rest%%/*}"
helper="$dir/goauth"
cat > "$helper" <<SH
#!/usr/bin/env bash
set -euo pipefail
token=\$(curl -fsS --retry 3 -H "Authorization: bearer \${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \\
  "\${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=$NORA_AUDIENCE" | jq -r .value)
[ -n "\$token" ] && [ "\$token" != null ] || { echo "go-nora: no OIDC token" >&2; exit 1; }
printf '%s\n\nAuthorization: Basic %s\n\n' "$origin" "\$(printf 'token:%s' "\$token" | base64 | tr -d '\\n')"
SH
chmod +x "$helper"

token=$(curl -fsS --retry 3 -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${NORA_AUDIENCE}" | jq -r .value)
[ -n "$token" ] && [ "$token" != null ] || { echo "::error::go-nora: no OIDC token" >&2; exit 1; }
echo "::add-mask::$token"

{
  echo "GOPROXY=$url/go"
  echo "GOAUTH=$helper"
} >> "$GITHUB_ENV"
echo "token=$token" >> "$GITHUB_OUTPUT"
echo "go: modules from $url/go (GOAUTH $helper)"
