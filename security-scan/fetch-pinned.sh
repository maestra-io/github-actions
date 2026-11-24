#!/usr/bin/env bash
# fetch-pinned.sh <url> <sha256> <file> [<direct url>]: a scanner binary/archive from nora, pinned by sha256.
# <file> sits in the job's cache directory (restored by actions/cache before this runs): when it
# is there with the pinned sha256 nothing is fetched; anything else is deleted and fetched from
# nora with the job's GitHub OIDC token, then checked. A fetch writes fetched=true to
# $GITHUB_OUTPUT, so only a fetch saves the cache. Needs id-token: write, except with <direct url>:
# a job without an OIDC token (gitleaks.yml, whose callers may not grant it, and fork PRs) gets the
# file from there, under the same sha256. With a token a refusal by nora is final.
set -euo pipefail
url=${1:?url} sum=${2:?sha256} f=${3:?file}
ok() { [ -s "$f" ] && echo "${sum}  ${f}" | sha256sum -c --status - 2>/dev/null; }
if ok; then
  echo "${f##*/}: from the runner cache (sha256 ${sum}), nothing fetched from nora"
  exit 0
fi
[ ! -e "$f" ] || { echo "::warning::${f##*/}: cached copy is not the sha256 pin, fetching it from nora"; rm -f "$f"; }
mkdir -p "$(dirname "$f")"
if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${4:-}" ]; then
  url=$4
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$f" "$url"
else
  : "${ACTIONS_ID_TOKEN_REQUEST_URL:?no GitHub OIDC token available: the job needs permissions: id-token: write}"
  oidc=$(curl -fsS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=packages.maestra.io" | jq -r .value)
  echo "::add-mask::${oidc}"
  # the credential reaches curl as a config on stdin, never on its command line
  printf 'user = "oidc:%s"\n' "$oidc" | curl -sfL --retry 5 --retry-delay 5 --retry-all-errors -K - -o "$f" "$url"
fi
ok || { rm -f "$f"; echo "::error::${url}: sha256 is not the pin ${sum}"; exit 1; }
echo "${f##*/}: fetched from ${url}"
[ -z "${GITHUB_OUTPUT:-}" ] || echo "fetched=true" >> "$GITHUB_OUTPUT"
