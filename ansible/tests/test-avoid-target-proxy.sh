#!/usr/bin/env bash
# Runs the "Keep the Teleport proxy on the target out of the path" step of
# ansible-run.yml — the block between its >>>/<<< markers, extracted, not copied —
# against stubbed getent/tsh/sudo, and checks what it writes to /etc/hosts.
# Offline: reads files, talks to nothing.
set -uo pipefail

WF=".github/workflows/ansible-run.yml"
OSU=".github/workflows/ansible-os-update.yml"
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed -n '/# >>> avoid-target-proxy/,/# <<< avoid-target-proxy/p' "$WF" | sed 's/^          //' > "$T/step.sh"
[ -s "$T/step.sh" ] || { echo "FAIL step markers not found in $WF"; exit 1; }

mkdir "$T/bin"
cat > "$T/bin/getent" <<'S'
#!/usr/bin/env bash
# /etc/hosts wins over DNS, as nsswitch "files dns" does.
src="$DNS_IPS"; [ -s "$HOSTS_FILE" ] && src=$(awk -v h="$3" '$2==h{print $1}' "$HOSTS_FILE")
for ip in $src; do echo "$ip STREAM $3"; done
S
cat > "$T/bin/tsh" <<'S'
#!/usr/bin/env bash
[ -n "${TSH_FAIL:-}" ] && exit 1; echo "$TARGET_ADDRS"
S
cat > "$T/bin/timeout" <<'S'
#!/usr/bin/env bash
shift; exec "$@"
S
cat > "$T/bin/sudo" <<'S'
#!/usr/bin/env bash
[ -n "${SUDO_FAIL:-}" ] && exit 1
[ "$1 $2 $3" = "tee -a /etc/hosts" ] && { cat >> "$HOSTS_FILE"; exit 0; }
exit 99
S
chmod +x "$T/bin/"*

IOTA="23.81.164.132 23.81.177.42 142.234.84.1"
run() {  # run <desc> <dns> <target addrs> <want hosts lines (sorted, ;-joined)> [ENV=1...]
  local desc="$1" dns="$2" addrs="$3" want="$4"; shift 4
  : > "$T/hosts"
  out=$(env "$@" PATH="$T/bin:$PATH" DNS_IPS="$dns" TARGET_ADDRS="$addrs" HOSTS_FILE="$T/hosts" \
        TELEPORT_PROXY=teleport.maestra.io:443 AVOID_HOST=target bash "$T/step.sh" 2>&1); rc=$?
  got=$(sort "$T/hosts" | paste -sd';' -)
  if [ "$rc" = 0 ] && [ "$got" = "$want" ]; then ok "$desc"
  else bad "$desc: rc=$rc hosts=[$got] want=[$want] out=$out"; fi
}

run "iota target: pinned to the two peers" "$IOTA" "23.81.177.42 10.60.8.1 100.121.199.14 fd00::1" \
  "142.234.84.1 teleport.maestra.io;23.81.164.132 teleport.maestra.io"
run "target holds no proxy address: nothing written" "$IOTA" "10.10.0.5 52.1.2.3" ""
run "target unreachable: fail open, nothing written" "$IOTA" "" "" TSH_FAIL=1
run "only proxy is on the target: never pin to nothing" "23.81.177.42" "23.81.177.42" ""
run "DNS empty: nothing written" "" "23.81.177.42" ""
run "no sudo (ARC): fail open" "$IOTA" "23.81.177.42" "" SUDO_FAIL=1

# The os-update apply leg must actually ask for it, with its own matrix host.
# Captured, not piped: under pipefail `awk | grep -q` fails with SIGPIPE when grep exits early.
apply=$(awk '/^  apply:/{f=1} /^  [a-z_-]+:$/ && !/^  apply:/{f=0} f' "$OSU")
grep -qF 'teleport_avoid_host: ${{ matrix.host }}' <<<"$apply" \
  && ok "apply job passes teleport_avoid_host: matrix.host" \
  || bad "apply job does not pass teleport_avoid_host: \${{ matrix.host }}"

[ "$fail" = 0 ] && echo "all passed" || { echo "$fail failure(s)"; exit 1; }
