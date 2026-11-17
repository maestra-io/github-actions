#!/usr/bin/env bash
# os_update /boot guard (boot_guard.yml): a tight /boot passes when a kernel GC
# would make room, `apply` runs that GC before the drain, and the GC is refused
# when it would touch a pinned package, the running kernel or the last fallback.
#   1. wiring: the guard runs after the plan and before preflight and the drain.
#   2. the REAL boot_guard.yml + kernel_gc.yml against fake apt-get/df/du/ls.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

R="ansible/collections/maestra/infra/roles/os_update/tasks"
T="ansible/tests/os-update-boot-gc"
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

echo "== wiring"
main=$(sed 's/#.*$//' "$R/main.yml")
ln() { echo "$main" | grep -n "$1" | head -1 | cut -d: -f1; }
plan=$(ln "include_tasks: plan.yml"); guard=$(ln "include_tasks: boot_guard.yml")
pre=$(ln "/preflight.yml"); drain=$(ln "/drain.yml")
[ -n "$plan" ] && [ -n "$guard" ] && [ "$plan" -lt "$guard" ] && [ "$guard" -lt "$pre" ] && [ "$guard" -lt "$drain" ] \
  && ok "plan -> boot_guard -> preflight -> drain" \
  || bad "boot_guard is not between the plan and the drain"
echo "$main" | grep -A3 "name: Reclaim /boot if it is tight" | grep -q "include_tasks: kernel_gc.yml$" \
  && ! echo "$main" | grep -A3 "name: Reclaim /boot if it is tight" | grep -q "os_update_gc_phase" \
  && ok "the post-reboot GC is still there, on its default phase" \
  || bad "the post-reboot GC changed"

echo "== boot_guard.yml against a fake host"
RUN=$(uname -r)   # what ansible_facts.kernel will be
OLD=0.0.1-1-test; MID=0.0.1-2-test; NEW1=9999.0.1-1-test; NEW2=9999.0.1-2-test
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# State: $S/free (MB), $S/kernels (one release per line), $S/size.<rel> (MB),
# $S/sim (apt-get -s autoremove output), $S/calls (every apt-get call).
cat > "$tmp/bin/apt-get" <<'SH'
#!/bin/sh
echo "$*" >> "$S/calls"
case " $* " in
  *" -s "*) cat "$S/sim" ;;
  *" autoremove "*)
    # The apt module reads "changed" off this block, as real apt-get prints it.
    printf 'The following packages will be REMOVED:\n  linux-image*\n'
    for rel in $(sed -n 's/^Purg linux-image-\([^ ]*\).*/\1/p' "$S/sim"); do
      [ -f "$S/size.$rel" ] || continue
      echo $(( $(cat "$S/free") + $(cat "$S/size.$rel") )) > "$S/free"
      grep -vx "$rel" "$S/kernels" > "$S/kernels.n"; mv "$S/kernels.n" "$S/kernels"
    done
    echo "0 upgraded, 0 newly installed, 3 to remove and 0 not upgraded." ;;
  *) echo "unexpected apt-get $*" >&2; exit 2 ;;
esac
SH
cat > "$tmp/bin/df" <<'SH'
#!/bin/sh
echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"
echo "/dev/fake 467 0 $(cat "$S/free") 0% /boot"
SH
cat > "$tmp/bin/du" <<'SH'
#!/bin/sh
for a in "$@"; do last=$a; done
f="$S/size.${last#/boot/\*-}"
[ -f "$f" ] && echo "$(cat "$f")	total" || { echo "0	total"; exit 1; }
SH
cat > "$tmp/bin/ls" <<'SH'
#!/bin/sh
case "$*" in
  *"/boot/vmlinuz-"*) sed 's|^|/boot/vmlinuz-|' "$S/kernels" ;;
  *) exec /bin/ls "$@" ;;
esac
SH
chmod +x "$tmp"/bin/*

# scenario <name> <mode> <free> <kernels...> -- <releases the simulation purges...>
# (EXTRA_SIM adds one raw simulation line)
scenario() {
  S="$tmp/$1"; mode=$2; free=$3; shift 3
  mkdir -p "$S"; echo "$free" > "$S/free"; : > "$S/kernels"; : > "$S/sim"; : > "$S/calls"
  while [ "$1" != "--" ]; do echo "$1" >> "$S/kernels"; shift; done; shift
  for rel in "$@"; do
    printf 'Purg linux-image-%s [1] \nPurg linux-modules-%s [1]\n' "$rel" "$rel" >> "$S/sim"
  done
  [ -z "${EXTRA_SIM:-}" ] || echo "$EXTRA_SIM" >> "$S/sim"
  newest=$(sort -V "$S/kernels" | tail -1)
  S="$S" PATH="$tmp/bin:$PATH" ANSIBLE_LOCALHOST_WARNING=false \
    ansible-playbook -i "us-test-node01," -c local \
    -e 'ansible_python_interpreter={{ ansible_playbook_python }}' \
    -e "os_update_mode=$mode boot_free=$free os_update_newest_kernel=$newest" \
    "$T/playbook.yml" > "$S/log" 2>&1
  rc=$?
}
# expect <what> <rc: 0|fail> <purged: yes|no> <text the log must carry>...
expect() {
  what=$1; want=$2; purged=$3; shift 3; good=1
  if [ "$want" = 0 ]; then [ "$rc" -eq 0 ] || good=0; else [ "$rc" -ne 0 ] || good=0; fi
  if grep -v -e '^-s ' "$S/calls" | grep -q autoremove; then did=yes; else did=no; fi
  [ "$did" = "$purged" ] || good=0
  for t in "$@"; do grep -qF -- "$t" "$S/log" || good=0; done
  if [ "$good" = 1 ]; then ok "$what"; else bad "$what (rc=$rc purged=$did)"; cat "$S/log"; fi
}
size() { mkdir -p "$tmp/$1"; echo "$2" > "$tmp/$1/size.$3"; }

size room-plan 91 "$OLD"
scenario room-plan plan 141 "$OLD" "$MID" "$RUN" -- "$OLD"
expect "plan: the GC makes room, the host passes with the line, nothing is removed" 0 no \
  "free_mb=141 wanted_mb=200 gc_removes=$OLD free_after_mb=232"

# kernel_gc.yml purges through the apt module, which needs python3-apt: Linux only.
if [ "$(uname -s)" = Linux ]; then
  size room-apply 91 "$OLD"
  scenario room-apply apply 141 "$OLD" "$MID" "$RUN" -- "$OLD"
  expect "apply: the GC runs before the drain, the guard passes on the measured value" 0 yes \
    "free_mb=141 wanted_mb=200 gc_removes=$OLD free_after_mb=232" \
    "(GC ran)" "final boot_free_mb=232"
else
  echo "  skip apply: the GC runs (apt module needs python3-apt, Linux only)"
fi

size no-room 20 "$OLD"
scenario no-room apply 141 "$OLD" "$MID" "$RUN" -- "$OLD"
expect "the GC cannot make room: fails with the numbers, nothing is removed" fail no \
  "/boot has only 141 MB free" "guard wants 200" "it would remove $OLD and leave 161 MB free"

scenario nothing apply 141 "$MID" "$RUN" --
expect "nothing removable: fails as before" fail no \
  "/boot has only 141 MB free" "do not drain a host we then cannot upgrade" "it would remove nothing and leave 141 MB free"

size run-oldest 91 "$NEW1"
scenario run-oldest plan 141 "$RUN" "$NEW1" "$NEW2" -- "$NEW1"
expect "running kernel is the oldest: it stays, the middle one goes" 0 no \
  "gc_removes=$NEW1 free_after_mb=232"

size run-listed 91 "$RUN"
scenario run-listed apply 141 "$RUN" "$NEW1" "$NEW2" -- "$RUN"
expect "a GC that lists the running kernel is refused" fail no "it would remove the running kernel"

size newest-listed 91 "$NEW2"
scenario newest-listed apply 141 "$RUN" "$NEW1" "$NEW2" -- "$NEW2"
expect "a GC that lists the newest kernel is refused" fail no "it would remove the newest kernel"

size no-fallback 91 "$OLD"
scenario no-fallback apply 141 "$OLD" "$RUN" -- "$OLD"
expect "a GC that leaves only the running kernel is refused" fail no "it would leave no fallback kernel"

size pinned 91 "$OLD"
EXTRA_SIM="Purg teleport [17.0.0]" scenario pinned apply 141 "$OLD" "$MID" "$RUN" -- "$OLD"
expect "a GC that would remove a pinned package is refused" fail no "it would remove a pinned package"

scenario roomy apply 300 "$OLD" "$MID" "$RUN" -- "$OLD"
expect "enough room already: no simulation, no GC" 0 no "/boot free 300 MB >= 200"
[ -s "$tmp/roomy/calls" ] && bad "apt-get was called on a host with enough room" || ok "apt-get never called on a host with enough room"

echo
if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "$fail failure(s)"; fi
[ "$fail" -eq 0 ]
