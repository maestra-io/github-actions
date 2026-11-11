#!/usr/bin/env bash
# os_update holds record (holds.yml): holds a run left behind after going
# UNREACHABLE are released by the next run, foreign pins stay.
#   1. wiring: the record is written before apt-mark hold; the undrain-only
#      hatch restores holds.
#   2. the REAL holds.yml restore path against a fake apt-mark.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

R="ansible/collections/maestra/infra/roles/os_update/tasks"
T="ansible/tests/os-update-holds"
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

echo "== wiring"
rec=$(grep -n "name: Record them before holding" "$R/holds.yml" | cut -d: -f1)
hold=$(grep -n "name: Hold them" "$R/holds.yml" | cut -d: -f1)
[ -n "$rec" ] && [ -n "$hold" ] && [ "$rec" -lt "$hold" ] \
  && ok "the record is written before apt-mark hold" \
  || bad "the record is not written before apt-mark hold"
sed 's/#.*$//' "$R/main.yml" | awk '/^- name: UNDRAIN-ONLY/{f=1} /end_host/{f=0} f' \
  | grep -A4 "holds.yml" | grep -q "os_update_holds_action: restore" \
  && ok "the undrain-only hatch restores holds" \
  || bad "the undrain-only hatch does not restore holds"

echo "== restore against a fake apt-mark"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/os-update"
printf 'consul\nfrr\nhaproxy\nteleport\n' > "$tmp/held"
cat > "$tmp/bin/apt-mark" <<'SH'
#!/bin/sh
st="$FAKE_APT_HELD"
while [ "$1" = "-o" ]; do shift 2; done
cmd=$1; shift
case $cmd in
  showhold) cat "$st" ;;
  unhold) for p in "$@"; do
            if grep -qx "$p" "$st"; then grep -vx "$p" "$st" > "$st.n"; mv "$st.n" "$st"; echo "Canceled hold on $p."; fi
          done ;;
  *) echo "unexpected apt-mark $cmd" >&2; exit 2 ;;
esac
SH
chmod +x "$tmp/bin/apt-mark"

PATH="$tmp/bin:$PATH" FAKE_APT_HELD="$tmp/held" ANSIBLE_LOCALHOST_WARNING=false \
  ansible-playbook -i "us-test-gw02," -c local -e "state_dir=$tmp" \
  -e 'ansible_python_interpreter={{ ansible_playbook_python }}' \
  "$T/playbook.yml" > "$tmp/play.log" 2>&1 \
  && ok "recorded holds released, foreign pin kept, record dropped, second restore a no-op" \
  || { bad "playbook failed"; cat "$tmp/play.log"; }

echo
if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "$fail failure(s)"; fi
[ "$fail" -eq 0 ]
