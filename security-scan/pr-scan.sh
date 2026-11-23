#!/usr/bin/env bash
# pr-scan.sh <gitleaks|trivy|opengrep>: the pull_request mode of security-scan.yml. Fails only
# on findings the PR INTRODUCES; findings already on the base branch never block a PR.
#
# Runs in the checkout of the PR's merge commit (what actions/checkout checks out on
# pull_request): HEAD is the merge, its first parent HEAD^1 the base it merges into.
#
#   gitleaks  `gitleaks git` over HEAD^1..HEAD: the PR's commits (their added lines; a merge in
#             the PR by its remerge diff), central config, redacted. Needs full history.
#   opengrep  `opengrep scan --baseline-commit HEAD^1`: only the files the PR changes are
#             scanned, and a match whose (rule id, path, matched lines) also matches at HEAD^1 is
#             dropped, so a finding moved by unrelated edits stays out (opengrep Diff_scan).
#             When there are findings, a full scan of the base copies of their files: in a copy
#             opengrep cannot fully parse (no matches for the baseline to drop) a finding whose
#             matched lines the base copy already has is old (pr-diff.py opengrep).
#             Skipped when the PR only deletes files: opengrep would scan no file.
#   trivy     `trivy fs` of HEAD; when it has findings, `trivy fs` of HEAD^1 too (a git
#             worktree, vulnerability DB not re-downloaded), and only the head findings whose key
#             is not in the base fail: vulnerability = (target, package, advisory id), secret =
#             (target, rule, sha256 of the matched lines). An old CVE never fails a PR; a bump into a new
#             HIGH/CRITICAL advisory or a newly added lockfile does. Skipping the base scan
#             when the head has no findings is exact: the difference is empty either way.
#
# Accepted findings as in the full scan: .gitleaksignore / gitleaks:allow, .trivyignore,
# nosemgrep. Env: GITLEAKS + GITLEAKS_CONFIG | TRIVY | OPENGREP + OPENGREP_RULES; OUT, a
# directory for the JSON reports (default: a temp dir). Exit 0 clean, 1 new findings, 2 broken.
set -euo pipefail
tool=${1:?usage: pr-scan.sh <gitleaks|trivy|opengrep>}
here=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$(mktemp -d)}
base=$(git rev-parse --verify -q 'HEAD^1') || { echo "pr-scan: HEAD has no parent commit: not a PR merge checkout" >&2; exit 2; }
echo "pr-scan $tool: base $base, head $(git rev-parse HEAD)"

case "$tool" in
gitleaks)
  # gitleaks exits 0 on a range git cannot resolve: resolve it first.
  n=$(git rev-list --count "$base..HEAD") || { echo "pr-scan: cannot list $base..HEAD (shallow clone?)" >&2; exit 2; }
  echo "scanning the $n commits of $base..HEAD"
  rc=0
  # --diff-merges=remerge: a merge inside the PR shows only what its author changed beyond the
  # automatic merge (a conflict resolution can add a secret neither parent has); a clean merge
  # of main shows nothing, so main's old findings stay out.
  "${GITLEAKS:?}" git --no-banner --config "${GITLEAKS_CONFIG:?}" --log-opts="--diff-merges=remerge $base..HEAD" \
    --redact=100 --verbose --exit-code 1 . || rc=$?
  [ "$rc" -le 1 ] || exit 2
  exit "$rc" ;;

opengrep)
  # A PR that only deletes files leaves opengrep no target (it scans the files the PR adds or
  # changes); skipping its ~3 min rule load gives the same empty result.
  if [ -z "$(git diff --name-only --diff-filter=d "$base" HEAD)" ]; then
    echo "the PR adds or changes no file: nothing to scan"; exit 0
  fi
  rc=0
  "${OPENGREP:?}" scan --config "${OPENGREP_RULES:?}" --severity=ERROR --taint-intrafile \
    --no-rewrite-rule-ids --error --baseline-commit "$base" \
    --json-output="$OUT/opengrep.json" . || rc=$?
  [ "$rc" -le 1 ] || exit 2
  [ "$rc" = 1 ] || exit 0
  # A base copy opengrep cannot fully parse has no matches for the baseline to drop: a full scan
  # of the base copies of the files with findings tells which, pr-diff.py compares those by text.
  wt=$(mktemp -d)/base
  git worktree add -q --detach "$wt" "$base" || { echo "pr-scan: cannot check out the base" >&2; exit 2; }
  trap 'git worktree remove --force "$wt"' EXIT
  targets=()
  while IFS= read -r f; do [ ! -f "$wt/$f" ] || targets+=("$wt/$f"); done \
    < <(jq -r '[.results[].path] | unique[]' "$OUT/opengrep.json")
  [ "${#targets[@]}" -gt 0 ] || exit 1  # every finding is in a file the PR adds
  "$OPENGREP" scan --config "$OPENGREP_RULES" --severity=ERROR --taint-intrafile --no-rewrite-rule-ids \
    --json-output="$OUT/opengrep-base.json" "${targets[@]}" > /dev/null \
    || { echo "pr-scan: opengrep scan of the base copies failed" >&2; exit 2; }
  rc=0; python3 "$here/pr-diff.py" opengrep "$OUT/opengrep.json" "$OUT/opengrep-base.json" "$wt" || rc=$?
  exit "$rc" ;;

trivy)
  "${TRIVY:?}" fs --severity HIGH,CRITICAL --exit-code 0 --format json --output "$OUT/trivy-head.json" . \
    || { echo "pr-scan: trivy fs of the head failed" >&2; exit 2; }
  rc=0; python3 "$here/pr-diff.py" any "$OUT/trivy-head.json" || rc=$?
  case $rc in
    0) ;;
    1) echo "no HIGH/CRITICAL findings at head: nothing the PR could introduce"; exit 0 ;;
    *) echo "pr-scan: cannot read the trivy report" >&2; exit 2 ;;
  esac
  wt=$(mktemp -d)/base
  git worktree add -q --detach "$wt" "$base" || { echo "pr-scan: cannot check out the base" >&2; exit 2; }
  trap 'git worktree remove --force "$wt"' EXIT
  # The vulnerability DB is the head scan's; the Java DB is left to trivy (the head may have no JAR).
  ( cd "$wt" && "$TRIVY" fs --severity HIGH,CRITICAL --exit-code 0 --skip-db-update \
      --format json --output "$OUT/trivy-base.json" . ) || { echo "pr-scan: trivy fs of the base failed" >&2; exit 2; }
  rc=0; python3 "$here/pr-diff.py" trivy "$OUT/trivy-base.json" "$OUT/trivy-head.json" "$wt" . || rc=$?
  exit "$rc" ;;

*) echo "pr-scan: unknown tool $tool" >&2; exit 2 ;;
esac
