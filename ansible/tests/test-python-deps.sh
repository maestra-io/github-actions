#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015  # ${{ }} is literal workflow text; ok/bad never fail
# The "python-deps" step block (ansible-pr lint, ansible-run, ansible-os-update
# enumerate, collection-lint): every copy identical, run against a stub `uv`.
# A uv.lock in uv_project -> `uv sync --locked` (nora only); none -> the step
# fails (no PyPI path). Plus the wiring around it. Offline: talks to nothing.
set -uo pipefail

WFS=(.github/workflows/ansible-pr.yml .github/workflows/ansible-run.yml
     .github/workflows/ansible-os-update.yml .github/workflows/collection-lint.yml)
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
block() { sed -n '/# >>> python-deps/,/# <<< python-deps/p' "$1" | sed 's/^          //'; }
block "${WFS[0]}" > "$T/step.sh"
[ -s "$T/step.sh" ] || { echo "FAIL python-deps markers not found in ${WFS[0]}"; exit 1; }
for wf in "${WFS[@]}"; do
  [ "$(grep -c '# >>> python-deps' "$wf")" -eq 1 ] || { bad "$wf: exactly one python-deps block"; continue; }
  if diff <(block "$wf") "$T/step.sh" > /dev/null; then ok "$wf: block identical"; else bad "$wf: block differs from ${WFS[0]}"; fi
done

mkdir "$T/bin"
cat > "$T/bin/uv" <<'S'
#!/usr/bin/env bash
echo "uv $* | env=${UV_PROJECT_ENVIRONMENT:-}" >> "$UV_LOG"
[ -z "${UV_FAIL:-}" ]
S
chmod +x "$T/bin/uv"
mkdir -p "$T/p"
cat > "$T/nora.lock" <<'L'
version = 1
[[package]]
name = "six"
version = "1.17.0"
source = { registry = "https://packages.maestra.io/simple/" }
sdist = { url = "https://packages.maestra.io/files/six-1.17.0.tar.gz", hash = "sha256:00" }
wheels = [
    { url = "https://packages.maestra.io/files/six-1.17.0-py2.py3-none-any.whl", hash = "sha256:00" },
]
L
sed 's|https://packages.maestra.io/files/six-1.17.0-py2|https://files.pythonhosted.org/packages/b7/ce/six-1.17.0-py2|' "$T/nora.lock" > "$T/pypi.lock"
sed 's|https://packages.maestra.io/files/six-1.17.0-py2|https://packages-maestra.io/files/six-1.17.0-py2|' "$T/nora.lock" > "$T/lookalike.lock"
sed 's|^source = .*|source = { git = "ssh://git@github.com/x/six.git?rev=1#abc" }|' "$T/nora.lock" > "$T/git.lock"
sed 's|^source = .*|source = { registry = "https://pypi.org/simple" }|' "$T/nora.lock" > "$T/index.lock"
sed 's|^source = .*|source = { path = "../six" }|' "$T/nora.lock" > "$T/path.lock"
printf '[[package]]\nname = "p"\nversion = "0"\nsource = { virtual = "." }\n' >> "$T/nora.lock"

run() {  # run <desc> <lock: nora|pypi|none> <want uv log line or FAIL> [ENV=...]
  local desc="$1" lock="$2" want="$3"; shift 3
  rm -f "$T/p/uv.lock" "$T/uv.log"; [ "$lock" = none ] || cp "$T/$lock.lock" "$T/p/uv.lock"
  out=$(cd "$T" && env -i PATH="$T/bin:/usr/bin:/bin" UV_LOG="$T/uv.log" DEPS_PROJECT=p DEPS_GROUP= \
        DEPS_TARGET=system pythonLocation=/opt/py \
        "$@" bash "$T/step.sh" 2>&1); rc=$?
  got=$(cat "$T/uv.log" 2>/dev/null)
  if [ "$want" = FAIL ]; then
    if [ "$rc" != 0 ] && [ -z "$got" ]; then ok "$desc"; else bad "$desc: rc=$rc uv=[$got] out=$out"; fi
  elif [ "$rc" = 0 ] && [ "$got" = "$want" ]; then ok "$desc"
  else bad "$desc: rc=$rc uv=[$got] want=[$want] out=$out"; fi
}

run "lock: sync into setup-python's interpreter, inexact" nora \
  "uv sync --locked --no-install-project --project p --inexact | env=/opt/py"
run "lock + lint group into the active venv" nora \
  "uv sync --locked --no-install-project --project p --group lint --active | env=" DEPS_GROUP=lint DEPS_TARGET=active
run "lock naming files.pythonhosted.org: refused, uv never runs" pypi FAIL
run "lock naming a look-alike host (packages-maestra.io): refused" lookalike FAIL
run "lock with a git (ssh) source: refused" git FAIL
run "lock with another registry: refused" index FAIL
run "lock with a path source: refused" path FAIL
run "system target without setup-python: refused" nora FAIL pythonLocation=
run "no lock: refused, nothing from PyPI" none FAIL
run "no lock, lint venv: refused" none FAIL DEPS_TARGET=active DEPS_GROUP=lint
# A failing uv sync must fail the step (set -e), not fall through.
rm -f "$T/uv.log"; cp "$T/nora.lock" "$T/p/uv.lock"
if (cd "$T" && env -i PATH="$T/bin:/usr/bin:/bin" UV_LOG="$T/uv.log" UV_FAIL=1 DEPS_PROJECT=p DEPS_TARGET=system \
    pythonLocation=/opt/py bash "$T/step.sh" > /dev/null 2>&1); then bad "a failing uv sync left the step green"
else ok "a failing uv sync fails the step"; fi

# Wiring: credentials before the install, the right target/groups, uv_project forwarded.
step_env() { awk -v n="      - name: $2" '$0 == n {f=1; next} f && /^      - / {exit} f' "$1"; }
chk() { if step_env "$1" "$2" | grep -qF -- "$3"; then ok "$1 [$2]: $3"; else bad "$1 [$2]: missing $3"; fi; }
chk .github/workflows/ansible-pr.yml "Install lint deps" "DEPS_GROUP: lint"
chk .github/workflows/ansible-pr.yml "Install lint deps" "DEPS_TARGET: active"
chk .github/workflows/ansible-pr.yml "Install lint deps" 'DEPS_PROJECT: ${{ inputs.uv_project }}'
chk .github/workflows/ansible-run.yml "Install ansible + Python dependencies" "DEPS_TARGET: system"
chk .github/workflows/ansible-run.yml "Install ansible + Python dependencies" 'DEPS_PROJECT: ${{ inputs.uv_project }}'
chk .github/workflows/ansible-os-update.yml "Install ansible" "DEPS_TARGET: system"
chk .github/workflows/ansible-os-update.yml "Install ansible" 'DEPS_PROJECT: ${{ inputs.uv_project }}'
chk .github/workflows/collection-lint.yml "Install lint deps" "DEPS_GROUP: lint"
for wf in "${WFS[@]}"; do
  nora=$(grep -n 'uses: maestra-io/github-actions/uv-nora@' "$wf" | head -1 | cut -d: -f1)
  inst=$(grep -n '# >>> python-deps' "$wf" | cut -d: -f1)
  if [ -n "$nora" ] && [ "$nora" -lt "$inst" ]; then ok "$wf: uv-nora before the install"; else bad "$wf: no uv-nora before the install"; fi
  if grep -A3 'astral-sh/setup-uv@' "$wf" | grep -q 'version: "0.13.6"' && ! grep -A3 'astral-sh/setup-uv@' "$wf" | grep -q 'enable-cache: true'
  then ok "$wf: setup-uv pinned, no cache"; else bad "$wf: setup-uv must pin version 0.13.6 and enable-cache: false"; fi
done
[ "$(grep -c 'uv_project: ${{ inputs.uv_project }}' .github/workflows/ansible-os-update.yml)" -eq 2 ] \
  && ok "os-update forwards uv_project to both ansible-run calls" || bad "os-update: uv_project not forwarded twice"
grep -qF 'uv_project: ${{ inputs.uv_project }}' .github/workflows/ansible-pr.yml \
  && ok "ansible-pr forwards uv_project to the check matrix" || bad "ansible-pr: uv_project not forwarded"

[ "$fail" = 0 ] && echo "all passed" || { echo "$fail failure(s)"; exit 1; }
