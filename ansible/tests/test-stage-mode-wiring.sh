#!/usr/bin/env bash
# `mode: stage` must never take a node out of rotation, and the reboot step must
# stay overridable by the consumer. Both properties are structural — they live in
# which tasks the role includes under which `when:` — so they are checked
# structurally. A unit test cannot catch "someone added a drain to the stage
# block"; this can.
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

echo "== stage mode wiring"

# The STAGE block, isolated: from its own `- name:` to the next top-level task.
# Comments stripped: the block explains at length that it does no cordon and no
# drain, so a bare substring check matches its own prose and fails on a correct
# file — which is what happened the first time this test ran.
stage_block=$(awk '/^- name: STAGE —/{f=1} f&&/^- name: APPLY/{f=0} f' "$MAIN" \
              | sed 's/#.*$//')
[ -n "$stage_block" ] || { bad "STAGE block not found in $MAIN"; echo "$fail failure(s)"; exit 1; }

# 1. The load-bearing property: staging is not a disruption. If any of these ever
#    appear inside the block, the mode has silently become a second apply — and it
#    would run WITHOUT preflight, which is only safe while it disrupts nothing.
for forbidden in drain.yml reboot.yml undrain.yml settle.yml verify.yml silence.yml cordon; do
  if echo "$stage_block" | grep -q -- "$forbidden"; then
    bad "STAGE block references '$forbidden' — stage must not disrupt the node"
  else
    ok "STAGE block does not reference $forbidden"
  fi
done

# 2. It must still hold the pinned packages, or a stage run can move teleport/frr/
#    consul out from under a node nobody drained.
echo "$stage_block" | grep -q "holds.yml" \
  && ok "STAGE applies the dpkg holds" \
  || bad "STAGE does not include holds.yml"
echo "$stage_block" | grep -q "os_update_holds_action: restore" \
  && ok "STAGE restores the hold set in always" \
  || bad "STAGE never restores holds"

# 3. And it must refuse a host somebody left drained: staging is invisible, so
#    doing it on top of a half-finished apply hides that apply behind a green run.
echo "$stage_block" | grep -q "os_update_resuming" \
  && ok "STAGE refuses to run on a host with a live drain marker" \
  || bad "STAGE does not check os_update_resuming"

# 4. preflight gates a drain stage never performs, and its kube implementation
#    refuses while ANY node is cordoned — permanently true under a platform
#    node-update wave, which is exactly when staging is most useful.
# -A20, not -A6: the task carries a long note between its name and its `when:`,
# and a window too short reports a correct file as broken.
grep -A20 "^- name: PREFLIGHT" "$MAIN" | grep -q "when: os_update_mode != 'stage'" \
  && ok "preflight is skipped in stage" \
  || bad "preflight is not gated on mode != stage"

# 5. The /boot guard is deferred in stage so the pre-stage GC can fix it first —
#    but it must still be asserted before anything is unpacked.
grep -B8 "^  ansible.builtin.assert:" "$ROLE/tasks/plan.yml" \
  | grep -q "os_update_mode != 'stage'" \
  && ok "plan's /boot guard is deferred for stage" \
  || bad "plan's /boot guard is not deferred for stage"
echo "$stage_block" | grep -q "os_update_boot_free_needed_mb" \
  && ok "STAGE re-asserts the /boot guard itself" \
  || bad "STAGE never re-asserts the /boot guard"

echo "== consumer-overridable reboot"
# A consumer with its own reboot.yml owns the reboot; one without keeps the SSH
# reboot untouched. That is what makes this change invisible to the pet-VM repos.
grep -A10 "ansible.builtin.include_tasks: \"{{ lookup('ansible.builtin.first_found', params) }}\"" "$MAIN" \
  | grep -q "os_update_hooks_dir }}/reboot.yml" \
  && ok "reboot resolves the consumer hook first" \
  || bad "reboot step does not prefer the consumer's reboot.yml"
grep -A10 "ansible.builtin.include_tasks: \"{{ lookup('ansible.builtin.first_found', params) }}\"" "$MAIN" \
  | grep -qE "^\s+- reboot\.yml" \
  && ok "reboot falls back to the role's own SSH reboot" \
  || bad "reboot step has no fallback to the role's reboot.yml"

echo "== workflow accepts the mode"
# No trailing `)`: the case arm grew a fifth mode (binary-update), and pinning
# the closing paren made this assertion fail on a correct file the moment
# another mode was added — which is the opposite of what it is for.
have "$WF" 'plan|stage|apply|undrain-only' \
  && ok "mode validation accepts stage" \
  || bad "workflow's mode case does not accept stage"
have "$WF" "inputs.mode == 'stage'" \
  && ok "the apply job runs for stage" \
  || bad "the apply job's if does not include stage"

echo "== stage must not be gated by the plan job"
# The plan job always runs the role with os_update_mode=plan, which runs the
# consumer preflight in full — gates that all decide whether a host may leave
# rotation. stage takes nothing out of rotation, and its whole purpose is to run
# WHILE a node-update wave is rolling; a wave means some node is cordoned or
# NotReady, so those gates refuse and a failed plan job skips the apply job.
# Two production runs died this way before the structural fix.
# -A40, not -A14: the job carries a long note between its name and its `if:`,
# and a window too short reports a correct file as broken (it did, first run —
# and again when binary-update added its own paragraph to that same note).
grep -A40 "^  plan:" "$WF" | grep -q "inputs.mode != 'stage'" \
  && ok "the plan job is skipped for stage" \
  || bad "the plan job still runs for stage — its preflight will refuse under a wave"
grep -A20 "needs: \[enumerate, plan\]" "$WF" | grep -q "inputs.mode == 'stage'" \
  && ok "the apply job does not require plan success for stage" \
  || bad "the apply job still requires plan success for stage"

echo "== kernel GC phases"
GC="$ROLE/tasks/kernel_gc.yml"
have "$GC" "os_update_gc_phase" \
  && ok "kernel_gc is phase-aware" \
  || bad "kernel_gc has no phase parameter"
# post-reboot must still be the default, or an apply run could purge the kernel it
# would have fallen back to.
have "$GC" "default('post-reboot')" \
  && ok "kernel_gc defaults to post-reboot" \
  || bad "kernel_gc does not default to post-reboot"

echo
if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "$fail failure(s)"; fi
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
