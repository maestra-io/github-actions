#!/usr/bin/env bash
# `mode: binary-update` has ONE property that must never regress, and it is the
# inverse of every other mode's: A HOST THAT FAILS STAYS DRAINED.
#
# That property is structural — it lives in WHICH block the undrain sits in, not
# in any value a unit test could assert. `apply` un-drains in `always`, so the
# single most natural "cleanup" edit to make to this new block (move the undrain
# next to the unsilence, like its neighbour does) silently converts it into a
# mode that puts an unproven binary back into rotation. Nothing would fail; the
# next bad build would just go live. So it is checked here, the same way
# test-stage-mode-wiring.sh checks that stage never grows a drain.
#
# Offline: reads files, talks to nothing.
set -uo pipefail

ROLE="ansible/collections/maestra/infra/roles/os_update"
MAIN="$ROLE/tasks/main.yml"
WF=".github/workflows/ansible-os-update.yml"
fail=0

ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
have() { grep -q -- "$2" "$1"; }

echo "== binary-update block"

# The BINARY-UPDATE block, isolated: from its own `- name:` to EOF (it is the
# last block in the file, deliberately — inserting it between STAGE and APPLY
# would land it inside test-stage-mode-wiring.sh's awk window and fail that test
# on a correct file). Comments stripped: the block explains at length what it
# does NOT do, so a bare substring check matches its own prose.
bin_block=$(awk '/^- name: BINARY-UPDATE —/{f=1} f' "$MAIN" | sed 's/#.*$//')
[ -n "$bin_block" ] || { bad "BINARY-UPDATE block not found in $MAIN"; echo "$fail failure(s)"; exit 1; }

# 1. THE invariant. Split the block at its `always:` and assert the undrain is on
#    the success side of that line. `always:` runs after a rescue, so an undrain
#    there is an undrain of a host we just failed to verify.
bin_always=$(echo "$bin_block" | awk '/^  always:/{f=1} f')
bin_before_always=$(echo "$bin_block" | awk '/^  always:/{f=1} !f')

echo "$bin_before_always" | grep -q "undrain.yml" \
  && ok "the undrain is on the success path" \
  || bad "BINARY-UPDATE does not undrain on success — the host would never come back"

echo "$bin_always" | grep -q "undrain.yml" \
  && bad "BINARY-UPDATE un-drains in 'always' — a host that failed verify would be put back into rotation" \
  || ok "'always' does not undrain (a failed host stays out of rotation)"

echo "$bin_always" | grep -q "marker.yml" \
  && bad "BINARY-UPDATE clears the drain marker in 'always' — OsUpdateHostStrandedDrain would never fire on a stranded host" \
  || ok "'always' does not clear the drain marker"

# 2. The silences MUST still be dropped unconditionally. A host we deliberately
#    leave drained is precisely the host whose alerts have to be free to fire.
echo "$bin_always" | grep -q "unsilence.yml" \
  && ok "'always' drops the silences even on the failure path" \
  || bad "BINARY-UPDATE does not unsilence in 'always' — a stranded host would sit silenced"

# 3. The job must go RED. A mode that leaves a host out of rotation behind a
#    green tick is worse than one that undrains.
echo "$bin_always" | grep -q "ansible.builtin.fail" \
  && ok "'always' fails the job when the block failed" \
  || bad "BINARY-UPDATE never fails the job — a drained host would end green"

# 4. It is a binary swap, not an OS patch. Any of these appearing means the mode
#    has quietly become a second apply, and it runs without the /boot guard.
for forbidden in apt.yml reboot.yml boot_safety.yml kernel_gc.yml holds.yml; do
  if echo "$bin_block" | grep -q -- "$forbidden"; then
    bad "BINARY-UPDATE references '$forbidden' — this mode patches no OS"
  else
    ok "BINARY-UPDATE does not reference $forbidden"
  fi
done

# 5. It still drains, silences and verifies — the three things that make the swap
#    safe. Dropping any one of them is the other way this mode could go wrong.
for required in silence.yml drain.yml verify-binary-update.yml settle.yml; do
  echo "$bin_block" | grep -q -- "$required" \
    && ok "BINARY-UPDATE includes $required" \
    || bad "BINARY-UPDATE does not include '$required'"
done

# 6. The consumer hooks are checked BEFORE the drain, not by the include that
#    needs them — otherwise a repo that never implemented the mode learns that
#    from a production host already out of rotation.
hook_guard_line=$(echo "$bin_block" | grep -n "os_update_binmode_hooks" | head -1 | cut -d: -f1)
drain_line=$(echo "$bin_block" | grep -n "/drain.yml" | head -1 | cut -d: -f1)
if [ -n "$hook_guard_line" ] && [ -n "$drain_line" ] && [ "$hook_guard_line" -lt "$drain_line" ]; then
  ok "the consumer-hook guard runs before the drain"
else
  bad "the consumer-hook existence guard does not precede the drain"
fi

echo "== plan.yml is not run in this mode"
# plan.yml is the apt/kernel report, and its /boot assert would refuse a run that
# unpacks no kernel at all.
grep -A12 "^- name: Plan — what would this update do" "$MAIN" \
  | grep -q "when: os_update_mode != 'binary-update'" \
  && ok "plan.yml is skipped in binary-update" \
  || bad "plan.yml still runs in binary-update — its /boot guard can refuse a kernel-less run"

echo "== preflight still runs"
# The peer gates are the reason a drain is safe. stage may skip them because it
# drains nothing; binary-update drains, so it must not.
grep -A20 "^- name: PREFLIGHT" "$MAIN" | grep -q "when: os_update_mode != 'stage'" \
  && ok "preflight runs in binary-update (only stage is exempt)" \
  || bad "preflight's gate no longer admits binary-update"

echo "== the one-at-a-time interlock covers this mode"
grep -B2 -A6 "exactly one host at a time" "$ROLE/tasks/guards.yml" \
  | grep -q "binary-update" \
  && ok "the contour-wide drain interlock includes binary-update" \
  || bad "binary-update is not covered by the one-host-at-a-time guard"

echo "== workflow wiring"
have "$WF" "binary-update)" \
  && ok "mode validation accepts binary-update" \
  || bad "workflow's mode case does not accept binary-update"
grep -A40 "^  plan:" "$WF" | grep -q "inputs.mode != 'binary-update'" \
  && ok "the plan job is skipped for binary-update" \
  || bad "the plan job still runs for binary-update"
grep -A20 "needs: \[enumerate, plan\]" "$WF" | grep -q "inputs.mode == 'binary-update'" \
  && ok "the apply job runs for binary-update without requiring plan" \
  || bad "the apply job's if does not include binary-update"

echo
if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "$fail failure(s)"; fi
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
