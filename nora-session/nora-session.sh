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
  mint() { # sets jwt only to a valid token
    local t i
    # Retried here, not by curl: a fresh pipe per attempt, so a body cut by
    # --max-time never sits in front of the next attempt's JSON.
    for i in 1 2 3; do
      t=$(curl -fsS --connect-timeout 10 --max-time 20 -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
        "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${aud}" | jq -r .value 2>/dev/null) && [ -n "$t" ] && [ "$t" != null ] && break
      t=; [ "$i" = 3 ] || sleep "$i"
    done
    [ -n "$t" ] || return 1
    echo "::add-mask::$t" >&2 # stderr: stdout is the token alone
    jwt=$t
  }
  mint || exit 1
  # The body goes to a file: curl truncates it before a retry, while stdout would keep a
  # failed attempt's body ("Service Unavailable") in front of the JSON (status-router#41).
  f=$(mktemp); trap 'rm -f "$f"' EXIT
  # Retries every 10 s for up to 150 s, each attempt capped at 20 s, so the whole
  # exchange ends by ~180 s: `--retry 3` gave up after ~7 s, while the exchange
  # answered 503 for 73 s on 16.11.2026 16:19 UTC and eu-central-1 runners lose
  # TCP to the us-iota edge for ~2-3 min at a 15-min cadence. A 10 s connect
  # timeout makes a lost SYN a fast retry on a fresh port.
  start=$SECONDS
  code=$(curl -sS --connect-timeout 10 --max-time 20 --retry 15 --retry-delay 10 --retry-max-time 150 \
    -X POST -H "Authorization: Bearer ${jwt}" -o "$f" -w '%{http_code}' \
    "${nora}/api/oidc/session") || { echo "::error::nora session exchange at $nora failed" >&2; exit 1; }
  case "$code" in
    200) session=$(jq -r '.token // empty' "$f") ;;
    # 404: a nora without the exchange; 403: a provider that grants no session.
    # After retries the first JWT may have little of its ~5 min left: mint a new one.
    403|404) [ $((SECONDS - start)) -lt 30 ] || mint || true # a failed refresh keeps the first
       echo "::warning::nora at $nora gives no session (HTTP $code): the OIDC token (~5 min) is used" >&2
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
