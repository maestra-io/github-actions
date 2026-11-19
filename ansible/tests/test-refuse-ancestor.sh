#!/usr/bin/env bash
# Runs `refuse_ancestor` from the "Refuse an ancestor of the branch tip" step of
# ansible-run.yml (the block between its >>>/<<< markers, extracted, not copied)
# in shallow clones of a local origin, and checks the step is opt-in and runs
# before any play.
# Offline: a file:// origin in a temp dir, talks to nothing.
set -uo pipefail

WF="$PWD/.github/workflows/ansible-run.yml"
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed -n '/# >>> refuse-ancestor/,/# <<< refuse-ancestor/p' "$WF" | sed 's/^          //' > "$T/block.sh"
[ -s "$T/block.sh" ] || { echo "FAIL block markers not found in $WF"; exit 1; }
# shellcheck source=/dev/null
. "$T/block.sh"

echo "== wiring"
# Flag off is a no-op: the step is skipped by its `if:`, and the input defaults to false.
input() { awk -v k="      $1:" '$0 == k {f=1; next} f && /^      [a-z_]+:$/ {exit} f' "$WF"; }
input refuse_ancestor_of_branch_tip | grep -qx '        default: false' \
  && ok "refuse_ancestor_of_branch_tip defaults to false" || bad "refuse_ancestor_of_branch_tip does not default to false"
input allow_rollback | grep -qx '        default: false' \
  && ok "allow_rollback defaults to false" || bad "allow_rollback does not default to false"
grep -A1 'name: Refuse an ancestor of the branch tip' "$WF" | grep -qx '        if: inputs.refuse_ancestor_of_branch_tip' \
  && ok "the step runs only when the caller opts in" || bad "the step is not gated on refuse_ancestor_of_branch_tip"
gate=$(grep -n 'name: Refuse an ancestor of the branch tip' "$WF" | cut -d: -f1)
first=$(grep -nE 'name: (Set up Python|Execute Ansible)' "$WF" | head -1 | cut -d: -f1)
[ -n "$gate" ] && [ -n "$first" ] && [ "$gate" -lt "$first" ] \
  && ok "the gate runs before setup and the play" || bad "the gate does not run before 'Set up Python'"

echo "== ancestry"
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
g init -q --bare "$T/origin.git"
g init -q "$T/src"
commit() { echo "$1" > "$T/src/f"; g -C "$T/src" add f; g -C "$T/src" commit -qm "$1"; g -C "$T/src" rev-parse HEAD; }
A=$(commit a); B=$(commit b)
g -C "$T/src" checkout -q -b other "$A"; C=$(commit c)
g -C "$T/src" push -q "$T/origin.git" "$B:refs/heads/main" "$C:refs/heads/other"

# run <sha> <ref> <allow>: in a fresh depth-1 clone of main, as actions/checkout leaves it
n=0
run() {
  n=$((n + 1))
  g clone -q --depth 1 --branch main "file://$T/origin.git" "$T/c$n" 2>/dev/null || { echo "clone failed"; return 2; }
  (cd "$T/c$n" && refuse_ancestor "$@") > "$T/out$n" 2>&1
}

run "$B" refs/heads/main false && ok "sha == tip: pass" || bad "sha == tip must pass: $(cat "$T/out$n")"
run "$A" refs/heads/main false && bad "an ancestor of the tip must fail" || ok "sha ancestor of the tip: fail"
grep -q '::error::refusing to run' "$T/out$n" && ok "the failure says why" || bad "no refusal message: $(cat "$T/out$n")"
run "$A" refs/heads/main true && ok "ancestor + allow_rollback: pass" || bad "ancestor + allow_rollback must pass: $(cat "$T/out$n")"
grep -q '::warning::rolling back' "$T/out$n" && ok "the rollback is a warning" || bad "no rollback warning"
run "$C" refs/heads/main false && ok "diverged: pass" || bad "diverged must pass: $(cat "$T/out$n")"
grep -q 'newer or diverged' "$T/out$n" && ok "diverged logs a line" || bad "diverged logs nothing: $(cat "$T/out$n")"
run "$A" refs/tags/v1 false && bad "a non-branch ref must fail" || ok "non-branch ref: fail"
run "$A" refs/heads/gone false && bad "an unfetchable branch must fail" || ok "missing branch: fail"

[ "$fail" -eq 0 ] && echo "refuse-ancestor: all ok" || { echo "refuse-ancestor: $fail failed"; exit 1; }
