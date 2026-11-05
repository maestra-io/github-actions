#!/usr/bin/env bash
# shellcheck disable=SC2016 # the eval'd expectations are single-quoted on purpose
# tbot-join/tbot-join.sh with a stub `tbot` on PATH: first-try success, transient
# failures then success (real 5 s / 15 s backoff, fresh outputs and work dir per
# attempt), configuration errors (no retry, accurate message), per-attempt
# timeout (a stub that never exits, one that ignores SIGTERM), a tbot that hangs
# after writing its outputs (heartbeat after a oneshot run), all attempts transient, stale outputs.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../tbot-join/tbot-join.sh"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin"

# The stub: one line per call in $STUB_STATE/calls (epoch, cwd, TMPDIR, whether
# the outputs existed at start), then behaves per $STUB_MODE.
cat > "$root/bin/tbot" <<'STUB'
#!/usr/bin/env bash
n=$(( $(wc -l < "$STUB_STATE/calls" 2>/dev/null || echo 0) + 1 ))
pre=absent; for f in $STUB_FILES; do [ -e "$f" ] && pre=present; done
echo "$n $(date +%s) $PWD $TMPDIR $pre" >> "$STUB_STATE/calls"
write() { for f in $STUB_FILES; do mkdir -p "$(dirname "$f")"; echo "eyJstub.$n" > "$f"; done; }
transient=(
  'ERROR: failed to join: rpc error: code = Unknown desc = too many retries, last error: failed to connect to `user=teleport database=teleport_backend`: server error: FATAL: the database system is shutting down (SQLSTATE 57P03)'
  'ERROR: failed to join: rpc error: code = Unknown desc = ERROR: could not serialize access due to concurrent update (SQLSTATE 40001)'
  "ERROR: failed to join: invalid character 'u' looking for beginning of value"
)
oidc_timeout='ERROR: Failed to join: rpc error: code = PermissionDenied desc = access denied: verifying OIDC token: validating with oidc: Get "https://token.actions.githubusercontent.com/.well-known/openid-configuration": context deadline exceeded'
case "$STUB_MODE" in
  ok) write; exit 0 ;;
  flaky) if [ "$n" -le "${STUB_FAILS:-2}" ]; then echo "${transient[$(( (n - 1) % 3 ))]}" >&2; exit 1; fi; write; exit 0 ;;
  transient) echo "${transient[$(( (n - 1) % 3 ))]}" >&2; exit 1 ;;
  notfound) echo 'ERROR: Failed to join: rpc error: code = PermissionDenied desc = token expired or not found' >&2; exit 1 ;;
  claims) echo 'ERROR: Failed to join: rpc error: code = PermissionDenied desc = id token claims did not match any allow rules' >&2; exit 1 ;;
  noidtoken) echo 'ERROR: getting github id token: ACTIONS_ID_TOKEN_REQUEST_URL environment variable missing' >&2; exit 1 ;;
  rbac) echo 'ERROR: issuing workload identity: access denied to perform action "read" on "workload_identity"' >&2; exit 1 ;;
  oidc-flaky) if [ "$n" -le 2 ]; then echo "$oidc_timeout" >&2; exit 1; fi; write; exit 0 ;;
  oidc-always) echo "$oidc_timeout" >&2; exit 1 ;;
  weird) echo 'ERROR: something nobody has seen before' >&2; exit 3 ;;
  hang) echo "joining..." >&2; exec sleep 600 ;;
  hang-ignore-term) trap '' TERM; echo "joining..." >&2; sleep 600 & wait; sleep 600 ;;
  hang-after-write) write; echo "outputs written, heartbeat..." >&2; exec sleep 600 ;;
esac
STUB
chmod +x "$root/bin/tbot"
printf 'version: v2\noneshot: true\nstorage:\n  type: memory\n' > "$root/tbot.yaml"

fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
# run <case> <mode> [env...]: sets out, rc, secs, calls, state, svid
run() {
  local case=$1 mode=$2; shift 2
  state="$root/$case"; mkdir -p "$state"; svid="$state/out/svid/jwt_svid"
  local t0; t0=$(date +%s)
  set +e
  out=$(env PATH="$root/bin:$PATH" STUB_MODE="$mode" STUB_STATE="$state" STUB_FILES="$svid" \
        RUNNER_TEMP="$state" "$@" \
        "$script" -c "$root/tbot.yaml" -r "$svid" -l "token image-push-github-actions-x" \
        -H "does the token exist in image-push-tokens.yaml, and does the job have id-token: write?" 2>&1)
  rc=$?
  set -e
  secs=$(( $(date +%s) - t0 ))
  calls=$(wc -l < "$state/calls" 2>/dev/null | tr -d ' ' || echo 0)
  echo "---- $case: rc=$rc calls=$calls ${secs}s"
  grep -E '^::(error|warning)::|retrying in|outputs in place' <<<"$out" | sed 's/^/     | /' || true
}
expect() { # <case> <condition-description> <test...>
  local c=$1 d=$2; shift 2
  if "$@"; then ok "$c: $d"; else fail "$c: $d"; fi
}
has() { grep -qF -- "$1" <<<"$out"; }
hasnt() { ! grep -qF -- "$1" <<<"$out"; }

# 1. success on the first try
run first-try ok
expect first-try "exit 0, one call, SVID written" test "$rc" -eq 0 -a "$calls" -eq 1 -a -s "$svid"
expect first-try "no retry, no annotation" eval '! has "retrying in" && ! has "::error::"'

# 2. transient twice, then success: the real backoff (5 s, 15 s), fresh outputs and work dir
run flaky-then-ok flaky STUB_FAILS=2
expect flaky-then-ok "exit 0 after 3 calls" test "$rc" -eq 0 -a "$calls" -eq 3
read -r -a t <<<"$(awk '{printf "%s ", $2}' "$state/calls")"
g1=$((t[1] - t[0])) g2=$((t[2] - t[1]))
echo "     | gaps between attempts: ${g1}s ${g2}s"
expect flaky-then-ok "backoff ~5 s then ~15 s (poll adds <= 1 s)" test "$g1" -ge 5 -a "$g1" -le 7 -a "$g2" -ge 15 -a "$g2" -le 17
expect flaky-then-ok "messages name the transient cause" eval 'has "retrying in 5s" && has "retrying in 15s" && has "SQLSTATE 40001"'
expect flaky-then-ok "every attempt in its own work dir (cwd and TMPDIR)" \
  test "$(awk '{print $3}' "$state/calls" | sort -u | wc -l | tr -d ' ')" -eq 3 -a "$(awk '{print $4}' "$state/calls" | sort -u | wc -l | tr -d ' ')" -eq 3
expect flaky-then-ok "cwd is attempt-1/2/3" test "$(awk '{n=split($3,a,"/"); printf "%s ", a[n]}' "$state/calls")" = "attempt-1 attempt-2 attempt-3 "
expect flaky-then-ok "outputs absent when each attempt starts" test "$(awk '{print $5}' "$state/calls" | sort -u)" = absent
expect flaky-then-ok "the SVID is the last attempt's" grep -qx 'eyJstub.3' "$svid"

# 3. configuration errors: one call, accurate message, the hint only here
for mode in notfound claims noidtoken rbac; do
  run "config-$mode" "$mode" TBOT_JOIN_BACKOFF="1 1 1"
  expect "config-$mode" "exit 1 after ONE call (no retry)" test "$rc" -eq 1 -a "$calls" -eq 1
  expect "config-$mode" "::error:: says configuration error, not retried, with the hint" \
    eval 'has "::error::tbot join (token image-push-github-actions-x) failed with a configuration error, not retried (attempt 1/4)" && has "image-push-tokens.yaml"'
  case "$mode" in
    notfound)  why="token expired or not found" ;;
    claims)    why="id token claims did not match any allow rules" ;;
    noidtoken) why="ACTIONS_ID_TOKEN_REQUEST_URL environment variable missing" ;;
    rbac)      why='access denied to perform action "read" on "workload_identity"' ;;
  esac
  expect "config-$mode" "quotes the reason: $why" eval 'grep "^::error::" <<<"$out" | grep -qF -- "$why"'
done

# 3b. a transient error wrapped in access denied (OIDC discovery timeout) is retried, not a config error
run oidc-timeout-in-denied oidc-flaky TBOT_JOIN_BACKOFF="1"
expect oidc-timeout-in-denied "exit 0 after 3 calls (retried)" test "$rc" -eq 0 -a "$calls" -eq 3
expect oidc-timeout-in-denied "classified transient" eval 'has "(transient: ERROR: Failed to join: rpc error: code = PermissionDenied desc = access denied: verifying OIDC token"'
run oidc-timeout-always oidc-always TBOT_JOIN_BACKOFF="1"
expect oidc-timeout-always "exit 1 after 4 calls; transient, with the config line and hint as a fallback" \
  eval '[ "$rc" -eq 1 ] && [ "$calls" -eq 4 ] && has "looks transient" && hasnt "It also reports" && has "Re-run the job; if it persists: does the token exist"'

# 4. per-attempt timeout: a tbot that never exits is killed at the timeout, every attempt
run timeout hang TBOT_JOIN_TIMEOUT=2 TBOT_JOIN_KILL_AFTER=1 TBOT_JOIN_BACKOFF="1"
expect timeout "exit 1 after 4 calls" test "$rc" -eq 1 -a "$calls" -eq 4
expect timeout "4 x 2 s + 3 x 1 s backoff, not 4 x 600 s" test "$secs" -ge 11 -a "$secs" -le 20
expect timeout "reported as transient timeout, without the config hint" \
  eval 'has "looks transient" && has "attempt timed out after 2s" && hasnt "image-push-tokens.yaml"'
run timeout-ignores-term hang-ignore-term TBOT_JOIN_ATTEMPTS=2 TBOT_JOIN_TIMEOUT=2 TBOT_JOIN_KILL_AFTER=1 TBOT_JOIN_BACKOFF="1"
expect timeout-ignores-term "SIGKILLed after -k: 2 x (2+1) s + 1 s" test "$rc" -eq 1 -a "$calls" -eq 2 -a "$secs" -ge 7 -a "$secs" -le 11

# 5. tbot hangs after writing (oneshot heartbeat): success without waiting for the timeout
run hang-after-write hang-after-write TBOT_JOIN_TIMEOUT=30
expect hang-after-write "exit 0, one call, stopped within the grace, not the 30 s timeout" test "$rc" -eq 0 -a "$calls" -eq 1 -a "$secs" -le 6

# 6. transient on every attempt: all 4 tried, final message transient, no config hint
run all-transient transient TBOT_JOIN_BACKOFF="1"
expect all-transient "exit 1 after 4 calls" test "$rc" -eq 1 -a "$calls" -eq 4
expect all-transient "final ::error:: says transient and quotes the last tbot error" \
  eval 'has "after 4 attempts; the last failure looks transient" && has "too many retries, last error: failed to connect" && hasnt "image-push-tokens.yaml"'
expect all-transient "last tbot output printed" has "--- last tbot output (attempt 4/4) ---"

# 7. unknown error: retried, reported as neither
run unknown weird TBOT_JOIN_BACKOFF="1"
expect unknown "exit 1 after 4 calls" test "$rc" -eq 1 -a "$calls" -eq 4
expect unknown "says neither transient nor configuration" has "neither a known transient nor a known configuration error: ERROR: something nobody has seen before"

# 8. a stale SVID from an earlier run does not count as this join's output
mkdir -p "$root/stale/out/svid"; echo stale > "$root/stale/out/svid/jwt_svid"
run stale notfound
expect stale "exit 1, stale SVID removed" test "$rc" -eq 1 -a ! -e "$svid"

# 9. -w (best-effort callers) annotates a warning
state="$root/warn"; mkdir -p "$state"
set +e
out=$(env PATH="$root/bin:$PATH" STUB_MODE=notfound STUB_STATE="$state" STUB_FILES="$state/k" RUNNER_TEMP="$state" \
      "$script" -c "$root/tbot.yaml" -r "$state/k" -w 2>&1); rc=$?
set -e
expect warning "-w: exit 1 with ::warning::, no ::error::" eval '[ "$rc" -eq 1 ] && has "::warning::tbot join failed with a configuration error" && hasnt "::error::"'

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all tbot-join cases passed"
