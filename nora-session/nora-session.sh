#!/usr/bin/env bash
# The job's GitHub OIDC token exchanged for a nora session token: `nrs_…`, the JWT's
# role and namespace scope, living the provider's session_lifetime_secs (1 h on iota),
# from nora's POST /api/oidc/session (issues-maestra#1649). For a credential written
# once (a Docker build secret, settings.xml, .npmrc): a raw JWT lives ~5 min.
# Sourced: `nora_token <nora url> <audience>` prints the token. Run: writes the masked
# `token` output (env NORA_URL, NORA_AUDIENCE, GITHUB_OUTPUT). Both read the runner's
# ACTIONS_ID_TOKEN_REQUEST_{URL,TOKEN}. A nora without the exchange (404) or a provider without
# sessions (403) gets the JWT, warned; any other answer fails.
nora_token() ( # a subshell: tracing is off inside it whatever the caller set
  set +x
  nora="${1%/}" aud="$2"
  jwt=$(curl -fsS --retry 3 -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${aud}" | jq -r .value) || exit 1
  [ -n "$jwt" ] && [ "$jwt" != null ] || exit 1
  echo "::add-mask::$jwt" >&2 # stderr: stdout is the token alone
  out=$(curl -sS --retry 3 -X POST -H "Authorization: Bearer ${jwt}" -w '\n%{http_code}' \
    "${nora}/api/oidc/session") || { echo "::error::nora session exchange at $nora failed" >&2; exit 1; }
  code="${out##*$'\n'}"
  case "$code" in
    200) session=$(jq -r .token <<<"${out%$'\n'*}") ;;
    # 404: a nora without the exchange; 403: a provider that grants no session.
    403|404) echo "::warning::nora at $nora gives no session (HTTP $code): the OIDC token (~5 min) is used" >&2
       printf '%s\n' "$jwt"; exit 0 ;;
    *) echo "::error::nora session exchange at $nora answered HTTP $code" >&2; exit 1 ;;
  esac
  case "$session" in
    nrs_*) printf '%s\n' "$session" ;;
    *) echo "::error::nora session exchange at $nora answered no session token" >&2; exit 1 ;;
  esac
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  : "${ACTIONS_ID_TOKEN_REQUEST_URL:?no GitHub OIDC token available: the job needs permissions: id-token: write}"
  token=$(nora_token "$NORA_URL" "$NORA_AUDIENCE") || { echo "::error::nora-session: no OIDC token" >&2; exit 1; }
  echo "::add-mask::$token"
  echo "token=$token" >> "$GITHUB_OUTPUT"
  echo "nora: session token for $NORA_URL"
fi
