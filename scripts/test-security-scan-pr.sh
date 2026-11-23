#!/usr/bin/env bash
# Tests for security-scan/pr-scan.sh (the pull_request mode of security-scan.yml) with the real
# scanners on fixture repos: each case is a base commit, a PR commit and the merge commit
# GitHub checks out on pull_request (HEAD^1 = base). Only findings the PR introduces fail.
# Needs GITLEAKS, GITLEAKS_CONFIG, TRIVY, OPENGREP, OPENGREP_RULES (security-scan-selftest.yml
# installs them as security-scan.yml does). The secret is generated per run, never committed
# and never printed: scanner output goes to files, shown only redacted on a failure.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

# A GitHub-token-shaped dummy (gitleaks rule github-pat): random, valid nowhere.
dummy_token() { printf 'ghp_%s' "$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 36)"; }

sqli() { # <function name> <SQL verb>
	printf '\n@app.route("/%s")\ndef %s():\n    name = flask.request.args.get("name")\n    return engine.execute("%s FROM person WHERE name = '"'"'" + name + "'"'"'")\n' "$1" "$1" "$2"
}

# base files: README.md, app/db.py (flask app), requirements.txt (a safe pin).
repo() {
	rm -rf "$work/repo"; mkdir -p "$work/repo/app"; cd "$work/repo"
	git init -q -b main . && git config user.email t@t && git config user.name t
	echo base > README.md
	printf 'import flask\n\napp = flask.Flask(__name__)\nengine = None\n' > app/db.py
	echo 'PyYAML==6.0.1' > requirements.txt
}
base_commit() { git add -A && git commit -qm base && git checkout -qb pr; }
# the PR commit, then the merge commit HEAD as on pull_request
pr_commit() { git add -A && git commit -qm pr && git checkout -q main && git merge -q --no-ff -m merge pr; }

run() { # <case> <tool> <want exit>
	local got=0
	OUT="$work/out" bash "$root/security-scan/pr-scan.sh" "$2" > "$work/log" 2>&1 || got=$?
	if [ "$got" = "$3" ]; then echo "ok   $1: $2 exit $got"
	else echo "FAIL $1: $2 exit $got, want $3"; sed 's/ghp_[A-Za-z0-9]*/ghp_REDACTED/g' "$work/log" | tail -40; fail=1; fi
}
mkdir -p "$work/out"

# 1. a new secret in the PR fails gitleaks and trivy
repo; base_commit
printf 'TOKEN = "%s"\n' "$(dummy_token)" > app/settings.py
pr_commit
run "new secret" gitleaks 1
run "new secret" trivy 1

# 2. a secret already on the base, untouched by the PR: passes
repo; printf 'TOKEN = "%s"\n' "$(dummy_token)" > app/settings.py; base_commit
echo change >> README.md
pr_commit
run "old secret untouched" gitleaks 0
run "old secret untouched" trivy 0

# 2b. the old secret replaced by another token of the same length on the same line: new (trivy
# redacts both to the same Match; the key hashes the real line)
repo; printf 'TOKEN = "%s"\n' "$(dummy_token)" > app/settings.py; base_commit
printf 'TOKEN = "%s"\n' "$(dummy_token)" > app/settings.py
pr_commit
run "secret replaced in place" trivy 1

# 2c. a secret that only a conflict resolution in the PR's merge of main adds: fails gitleaks;
# a clean merge of main into the PR adds nothing
repo; echo one > app/notes.txt; base_commit
echo pr > app/notes.txt; git commit -qam pr1
git checkout -q main; echo main > app/notes.txt; echo m > app/main.txt; git add -A; git commit -qm main2
git checkout -q pr; git merge -q main > /dev/null 2>&1 || true  # conflicts by design
printf 'TOKEN = "%s"\n' "$(dummy_token)" > app/notes.txt; git add -A; git commit -qm "merge main, resolved"
git checkout -q main; git merge -q --no-ff -m merge pr
run "secret only in a conflict resolution" gitleaks 1
repo; base_commit
echo pr > app/pr.txt; git add -A; git commit -qm pr1
git checkout -q main; printf 'TOKEN = "%s"\n' "$(dummy_token)" > app/old.py; git add -A; git commit -qm "main: an old secret"
git checkout -q pr; git merge -q --no-edit main; git checkout -q main; git merge -q --no-ff -m merge pr
run "clean merge of main (main has a secret)" gitleaks 0

# 3. a new SQL injection fails opengrep
repo; base_commit
sqli new_one DELETE >> app/db.py
pr_commit
run "new sqli" opengrep 1
n=$(jq '.results | length' "$work/out/opengrep.json" 2>/dev/null || echo 0)
if [ "$n" -gt 0 ]; then echo "ok   new sqli: $n result(s) in the report"; else echo "FAIL new sqli: no result in the opengrep report"; fail=1; fi

# 4. an old SQL injection moved down its file by unrelated lines: passes
repo; sqli old_one SELECT >> app/db.py; base_commit
{ head -4 app/db.py; printf '\n\ndef health():\n    return "ok"\n'; tail -n +5 app/db.py; } > app/db.py.new && mv app/db.py.new app/db.py
pr_commit
run "moved old sqli" opengrep 0
# not vacuous: the head has the finding, the baseline is what drops it
if grep -qE 'Current version has [1-9]' "$work/log"; then echo "ok   moved old sqli: found at head, dropped by the baseline"; else echo "FAIL moved old sqli: no finding at head, the case proves nothing"; fail=1; fi

# 5. a dependency bump into a vulnerable version (PyYAML 5.3: CVE-2020-14343) fails trivy
repo; base_commit
echo 'PyYAML==5.3' > requirements.txt
pr_commit
run "bump into a vulnerable version" trivy 1

# 6. an unrelated PR on a base with an old secret, sqli and CVE: every tool passes
repo; printf 'TOKEN = "%s"\n' "$(dummy_token)" > app/settings.py; sqli old_one SELECT >> app/db.py
echo 'PyYAML==5.3' > requirements.txt; base_commit
echo change >> README.md
pr_commit
run "unrelated PR" gitleaks 0
run "unrelated PR" opengrep 0
run "unrelated PR" trivy 0

# 7. a PR that only deletes a file (with an old sqli in it): opengrep has nothing to scan
repo; sqli old_one SELECT >> app/db.py; base_commit
git rm -q app/db.py
pr_commit
run "deletion-only PR" opengrep 0
if grep -q "nothing to scan" "$work/log"; then echo "ok   deletion-only PR: opengrep skipped"; else echo "FAIL deletion-only PR: opengrep not skipped"; fail=1; fi

# 8. not a merge checkout: broken, never green
repo; git add -A && git commit -qm only
run "no parent commit" gitleaks 2

# 9. a Dockerfile opengrep cannot fully parse (a bare `,rw` mount option; 1.33.1 skips the lines
# after it, so the base has no match for the baseline to drop): an old CMD without USER under an
# edited RUN passes (py-reports#37 failed on it, run 44814697416); the same CMD repeated in a new
# stage fails (the base copy has that text once)
dockerfile() { # <the RUN line above the last CMD> [extra lines]
	printf '%s\n' 'FROM python:3.12-slim AS base' 'WORKDIR /opt' \
		"RUN --mount=type=bind,from=busybox,source=/bin,target=/b \\" \
		"    --mount=type=bind,from=busybox,source=/x,target=/x,rw \\" '    echo hi' '' \
		'WORKDIR /opt/src' '' "$1" '' 'CMD ["python3", "-m", "pytest"]' "${@:2}" > Dockerfile
}
repo; dockerfile 'RUN pipconflictchecker'; base_commit
dockerfile 'RUN python3 -m pip check'
pr_commit
run "old CMD in an unparsed Dockerfile" opengrep 0
if grep -q 'not fully parsed at the base' "$work/log"; then echo "ok   old CMD in an unparsed Dockerfile: found at head, the base copy's text drops it"; else echo "FAIL old CMD in an unparsed Dockerfile: the base was not compared, the case proves nothing"; fail=1; fi
repo; dockerfile 'RUN pipconflictchecker'; base_commit
dockerfile 'RUN python3 -m pip check' '' 'FROM base AS worker' 'CMD ["python3", "-m", "pytest"]'
pr_commit
run "old CMD repeated in a new stage of an unparsed Dockerfile" opengrep 1

[ "$fail" = 0 ] && echo "all security-scan PR mode cases passed"
exit "$fail"
