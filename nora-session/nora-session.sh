#!/usr/bin/env bash
# The job's GitHub OIDC token exchanged for a nora session token: `nrs_…`, the JWT's
# role and namespace scope, living the provider's session_lifetime_secs (1 h on iota),
# from nora's POST /api/oidc/session (issues-maestra#1649). For a credential written
# once (a Docker build secret, settings.xml, .npmrc): a raw JWT lives ~5 min.
# Sourced: `nora_token <nora url> <audience>` prints the token. Run: writes the masked
# `token` output (env NORA_URL, NORA_AUDIENCE, GITHUB_OUTPUT). Both read the runner's
# ACTIONS_ID_TOKEN_REQUEST_{URL,TOKEN}. A nora without the exchange gets the JWT, warned.
nora_token() {
  local url="${1%/}" aud="$2" jwt session
  jwt=$(curl -fsS --retry 3 -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${aud}" | jq -r .value) || return 1
  [ -n "$jwt" ] && [ "$jwt" != null ] || return 1
  session=$(curl -fsS --retry 3 -X POST -H "Authorization: Bearer ${jwt}" \
    "${url}/api/oidc/session" | jq -r .token) || session=
  case "$session" in
    nrs_*) printf '%s\n' "$session" ;;
    *) echo "::warning::nora session exchange at $url failed: the OIDC token (~5 min) is used" >&2
       printf '%s\n' "$jwt" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  : "${ACTIONS_ID_TOKEN_REQUEST_URL:?no GitHub OIDC token available: the job needs permissions: id-token: write}"
  token=$(nora_token "$NORA_URL" "$NORA_AUDIENCE") || { echo "::error::nora-session: no OIDC token" >&2; exit 1; }
  echo "::add-mask::$token"
  echo "token=$token" >> "$GITHUB_OUTPUT"
  echo "nora: session token for $NORA_URL"
fi
