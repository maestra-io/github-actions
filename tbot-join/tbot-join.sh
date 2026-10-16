#!/usr/bin/env bash
# Join Teleport with tbot and wait for its one-shot outputs (a workload-identity
# JWT SVID, a kubeconfig, an app certificate), retrying transient failures.
#
# One implementation for every tbot join in this repo:
#   - composite actions (push-to-aws-ecr-repository, push-helm-chart-to-aws-ecr,
#     bake-oci-manifests) run it as ${GITHUB_ACTION_PATH}/../tbot-join/tbot-join.sh,
#     i.e. from the same ref as the action itself;
#   - workflows (a reusable one runs in the caller's checkout) reach it through
#     the composite action next to this file (maestra-io/github-actions/tbot-join).
#     None in this repo uses it since the build workflows dropped kargo-refresh.
#
# usage: tbot-join.sh -c <tbot.yaml> -r <file> [-r <file>...] [-l <label>] [-H <hint>] [-w]
#   -c  tbot config (directory destinations, `storage: memory`, `oneshot: true`)
#   -r  output file that must exist and be non-empty for the join to count (repeatable)
#   -l  what is joining, for messages (e.g. "token image-push-github-actions-x")
#   -H  hint printed only when the failure is a configuration error
#   -w  report the final failure as ::warning:: (best-effort callers), not ::error::
#
# Each attempt starts from nothing: the -r files are deleted, tbot runs as a new
# process (memory storage: no bot identity carries over) in a new work dir that
# is also its cwd and TMPDIR, under `timeout -k 5 45`. It counts only when every
# -r file is non-empty; tbot is then stopped, because its heartbeat can hang for
# minutes after a one-shot run's outputs land. Up to 4 attempts, 5 s / 15 s / 30 s
# apart (worst case ~4 min). Seen transient on 2026-10-13: Teleport's Postgres
# backend switching primary ("too many retries, last error: failed to connect",
# "could not serialize access (SQLSTATE 40001)"), GitHub's OIDC token endpoint
# answering non-JSON ("invalid character 'u' looking for beginning of value"),
# the auth server timing out on GitHub's OIDC discovery ("verifying OIDC token
# ... context deadline exceeded"). A configuration error (unknown token, claims
# not matching the token's allow rules, RBAC, no `id-token: write`) with no
# transient error next to it fails at once: retrying cannot fix it.
#
# Exit 0 when the outputs are in place, 1 otherwise. The test is
# scripts/test-tbot-join.sh (stub tbot on PATH).
set -uo pipefail

attempts=${TBOT_JOIN_ATTEMPTS:-4}
attempt_timeout=${TBOT_JOIN_TIMEOUT:-45}
kill_after=${TBOT_JOIN_KILL_AFTER:-5}
read -r -a backoff <<<"${TBOT_JOIN_BACKOFF:-5 15 30}"
poll=${TBOT_JOIN_POLL:-1}
grace=${TBOT_JOIN_GRACE:-3}  # polls tbot gets to exit on its own once the outputs landed
tbot_bin=${TBOT_BIN:-tbot}

config='' label='' hint='' level=error
required=()
while getopts 'c:r:l:H:w' opt; do
  case "$opt" in
    c) config=$OPTARG ;;
    r) required+=("$OPTARG") ;;
    l) label=$OPTARG ;;
    H) hint=$OPTARG ;;
    w) level=warning ;;
    *) echo "usage: $0 -c <tbot.yaml> -r <file> [-r <file>...] [-l <label>] [-H <hint>] [-w]" >&2; exit 2 ;;
  esac
done
if [ -z "$config" ] || [ "${#required[@]}" -eq 0 ]; then
  echo "usage: $0 -c <tbot.yaml> -r <file> [-r <file>...] [-l <label>] [-H <hint>] [-w]" >&2; exit 2
fi
[ -f "$config" ] || { echo "::error::tbot-join: config $config not found"; exit 2; }

abspath() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
config=$(abspath "$config")
for i in "${!required[@]}"; do required[i]=$(abspath "${required[i]}"); done
what="tbot join${label:+ (${label})}"

# Errors that a retry cannot fix (Teleport v18 lib/auth, lib/join): unknown or
# expired token, OIDC claims outside the token's allow rules, wrong join method
# or role on the token, RBAC on the workload identity, and a job without
# `id-token: write` (tbot then has no ACTIONS_ID_TOKEN_REQUEST_* env).
config_re='token expired or not found|did not match any allow rules|ACTIONS_ID_TOKEN_REQUEST_(URL|TOKEN) environment variable missing|provision token only supports method|token does not allow role|required github configuration is missing|workload identity failed evaluation|workload_identity "[^"]*" not found|access denied'
# Known transient shapes (backend, GitHub OIDC, network). They win over a
# configuration match in the same output: a backend or OIDC-discovery failure
# can come back wrapped in an access-denied error, and a needless retry costs
# seconds where a wrong fail-fast costs the release. Anything matching neither
# is retried too.
transient_re='too many retries|SQLSTATE|could not serialize|failed to connect|deadline exceeded|invalid character|connection refused|connection reset|i/o timeout|unexpected EOF|: EOF|code = Unavailable|TLS handshake timeout|no such host|server misbehaving|temporarily unavailable|bad gateway|service unavailable|gateway timeout'

outputs_ready() {
  local f
  for f in "${required[@]}"; do [ -s "$f" ] || return 1; done
}

# classify <log> <rc>: sets kind (config|transient|unknown), reason (one line)
# and config_line (a configuration-error line seen next to a transient one).
oneline() { printf '%s' "$1" | tr -s '[:space:]' ' ' | sed 's/ $//' | cut -c1-300; }
classify() {
  local line
  config_line=$(oneline "$(grep -m1 -iE -- "$config_re" "$1")")
  if line=$(grep -m1 -iE -- "$transient_re" "$1"); then
    kind=transient reason=$line
  elif [ "$2" -eq 124 ] || [ "$2" -eq 137 ]; then
    kind=transient reason="attempt timed out after ${attempt_timeout}s"
  elif [ -n "$config_line" ]; then
    kind=config reason=$config_line config_line=''
  else
    kind=unknown
    reason=$(grep -v '^[[:space:]]*$' "$1" | tail -n 1)
    [ -n "$reason" ] || reason="tbot exited ${2} with no output"
  fi
  reason=$(oneline "$reason")
}

annotate() { # <level> <message>; % CR LF are workflow-command escapes
  local msg=${2//'%'/%25}
  echo "::$1::${msg}"
}

files_list=$(printf '%s, ' "${required[@]}"); files_list=${files_list%, }
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tbot-join.XXXXXX")
kind='' reason='' log='' config_line=''
n=0
while [ "$n" -lt "$attempts" ]; do
  n=$((n + 1))
  adir="$work/attempt-$n"
  mkdir -p "$adir/tmp"
  log="$adir/tbot.log"
  rm -f "${required[@]}"
  for f in "${required[@]}"; do mkdir -p "$(dirname "$f")"; done

  # Background + poll, not foreground: success is the outputs, not tbot's exit.
  (cd "$adir" && TMPDIR="$adir/tmp" exec timeout -k "$kill_after" "$attempt_timeout" \
    "$tbot_bin" start -c "$config") >"$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if outputs_ready; then
      g=0
      while [ "$g" -lt "$grace" ] && kill -0 "$pid" 2>/dev/null; do sleep "$poll"; g=$((g + 1)); done
      kill "$pid" 2>/dev/null  # `timeout` forwards it to tbot, and SIGKILLs after -k
      break
    fi
    sleep "$poll"
  done
  wait "$pid"; rc=$?

  echo "::group::tbot attempt ${n}/${attempts} (exit ${rc})"
  cat "$log"
  echo "::endgroup::"

  if outputs_ready; then
    echo "${what}: outputs in place after attempt ${n}/${attempts}"
    exit 0
  fi

  classify "$log" "$rc"
  if [ "$kind" = config ]; then
    echo "--- last tbot output (attempt ${n}/${attempts}) ---"; tail -n 25 "$log"
    annotate "$level" "${what} failed with a configuration error, not retried (attempt ${n}/${attempts}): ${reason}${hint:+. ${hint}}"
    exit 1
  fi
  if [ "$n" -lt "$attempts" ]; then
    i=$((n - 1)); [ "$i" -lt "${#backoff[@]}" ] || i=$((${#backoff[@]} - 1))
    delay=${backoff[i]}
    echo "${what}: attempt ${n}/${attempts} produced no ${files_list} (${kind}: ${reason}); retrying in ${delay}s"
    sleep "$delay"
  fi
done

echo "--- last tbot output (attempt ${attempts}/${attempts}) ---"; tail -n 25 "$log"
if [ "$kind" = transient ]; then
  msg="${what} produced no ${files_list} after ${attempts} attempts; the last failure looks transient (Teleport backend / GitHub OIDC / network): ${reason}."
  # A configuration-error line next to the transient one: say so, and keep the hint.
  if [ -n "$config_line" ] && [ "$config_line" != "$reason" ]; then msg+=" It also reports: ${config_line}."; fi
  if [ -n "$config_line" ]; then msg+=" Re-run the job; if it persists: ${hint:-check the token and the job id-token: write permission}"
  else msg+=" Re-run the job."; fi
  annotate "$level" "$msg"
else
  annotate "$level" "${what} produced no ${files_list} after ${attempts} attempts; the last failure is neither a known transient nor a known configuration error: ${reason}"
fi
exit 1
