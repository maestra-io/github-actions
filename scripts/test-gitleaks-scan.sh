#!/usr/bin/env bash
# Tests for the gitleaks-scan block of gitleaks.yml with the real gitleaks on fixture repos: the
# checkout is the PR's merge commit, as on pull_request. A secret in any PR commit fails the job
# and is never printed. Needs GITLEAKS and GITLEAKS_TOML (security-scan-selftest.yml installs the
# pinned one). The secret is generated per run.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
wf="$root/.github/workflows/gitleaks.yml"
: "${GITLEAKS:?}" "${GITLEAKS_TOML:?}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

sed -n '/# >>> gitleaks-scan/,/# <<< gitleaks-scan/p' "$wf" | sed 's/^          //' > "$work/block.sh"
[ -s "$work/block.sh" ] || { echo "FAIL no gitleaks-scan block in $wf"; exit 1; }

# A GitHub-token-shaped dummy (gitleaks rule github-pat): random, valid nowhere.
token() { printf 'ghp_%s' "$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 4096 /dev/urandom) | head -c 36)"; }

repo() {
	rm -rf "$work/repo"; mkdir "$work/repo"; cd "$work/repo"
	git init -q -b main . && git config user.email t@t && git config user.name t
	echo base > README.md; git add -A && git commit -qm base && git checkout -qb pr
}
commit() { git add -A && git commit -qm "$1"; }
merge() { git checkout -q main && git merge -q --no-ff -m merge pr; }

run() { # <case> <want exit> [<pattern the output or summary must have>]
	local got=0
	: > "$work/summary"
	GITHUB_STEP_SUMMARY="$work/summary" bash "$work/block.sh" > "$work/log" 2>&1 || got=$?
	if grep -qE 'ghp_[A-Za-z0-9]{36}' "$work/log" "$work/summary"; then echo "FAIL $1: the secret was printed"; fail=1
	elif [ "$got" != "$2" ]; then echo "FAIL $1: exit $got, want $2"; sed 's/ghp_[A-Za-z0-9]*/ghp_REDACTED/g' "$work/log" | tail -20; fail=1
	elif [ -n "${3:-}" ] && ! cat "$work/log" "$work/summary" | grep -qE -- "$3"; then echo "FAIL $1: no match for $3"; fail=1
	else echo "ok   $1: exit $got"; fi
}

repo; echo x > a.txt; commit a; merge
run "clean PR" 0 "scanning 1 first-parent"

repo; printf 'TOKEN = "%s"\n' "$(token)" > settings.py; commit secret; merge
run "seeded secret: annotation" 2 '^::error file=settings\.py,line=1,title=gitleaks github-pat::'
run "seeded secret: fingerprint in the summary" 2 '^[0-9a-f]{40}:settings\.py:github-pat:1$'

repo; printf 'TOKEN = "%s"\n' "$(token)" > settings.py; commit secret; rm settings.py; commit "remove it"; merge
run "secret removed by a later commit of the PR" 2

repo; for i in $(seq 1 40); do
	[ "$i" != 35 ] || printf 'TOKEN = "%s"\n' "$(token)" > settings.py
	echo "$i" > n.txt; commit "c$i"
done; merge
run "secret in commit 35 of 40" 2 "scanning 40 first-parent"

repo; printf 'TOKEN = "%s"\n' "$(token)" > 'a,b:c%d.py'; commit secret; merge
run "file name escaped in the annotation" 2 '^::error file=a%2Cb%3Ac%25d\.py,line=1,'

repo; printf 'TOKEN = "%s"\n' "$(token)" > settings.py; commit secret
echo "$(git rev-parse HEAD):settings.py:github-pat:1" > .gitleaksignore; commit ignore; merge
run "accepted in .gitleaksignore" 0

repo; echo x > a.txt; commit a; git checkout -q main
printf 'TOKEN = "%s"\n' "$(token)" > old.py; commit "old secret on main"
git checkout -q pr; git merge -q -m "merge main" main; merge
run "old secret of main merged into the PR" 0

repo; echo x > a.txt; commit a
run "not a merge commit" 1 "not the PR's merge commit"

repo; echo x > a.txt; commit a; merge
GITLEAKS_TOML="$work/missing.toml" run "gitleaks cannot start (config missing)" 1 "gitleaks failed"

exit "$fail"
