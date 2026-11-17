#!/usr/bin/env bash
# Self-check for the upload program inlined in python-package-publish.yml: a file
# already on /simple/<project>/ is skipped, a 409 counts as uploaded, any other
# upload error fails, twine is pinned and never gets --skip-existing (twine 7.0
# refuses it for non-PyPI repositories), twine comes through nora (uvx --default-index).
# curl and uvx are stubs on PATH.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../.github/workflows/python-package-publish.yml"
prog=$(sed -n '/# pypi-upload: begin/,/# pypi-upload: end/p' "$wf" | sed 's/^          //')
[ -n "$prog" ] || { echo "pypi-upload program not found in $wf"; exit 1; }
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
mkdir -p "$d/bin" "$d/index/ml-commons" "$d/work/dist"

# curl stub: serves $d/index/<project>/index.html for .../<project>/, else 404.
cat > "$d/bin/curl" <<'X'
#!/usr/bin/env bash
url="${*: -1}"; p="${url%/}"; p="${p##*/}"
echo "$url" >> "$STUB/curl.log"
[ -f "$STUB/index/$p/index.html" ] || exit 22
cat "$STUB/index/$p/index.html"
X
# uvx stub: logs argv; a file named in $STUB/409 answers 409, in $STUB/500 fails.
cat > "$d/bin/uvx" <<'X'
#!/usr/bin/env bash
echo "$*" >> "$STUB/uvx.log"
f="${*: -1}"; f="${f##*/}"
grep -qxF "$f" "$STUB/409" 2>/dev/null && { echo "HTTPError: 409 Conflict from $TWINE_REPOSITORY_URL"; exit 1; }
grep -qxF "$f" "$STUB/500" 2>/dev/null && { echo "HTTPError: 500 Internal Server Error"; exit 1; }
echo "Uploading $f"
X
chmod +x "$d/bin/curl" "$d/bin/uvx"
echo '<a href="../../files/ml_commons-0.0.5-py3-none-any.whl">ml_commons-0.0.5-py3-none-any.whl</a>' > "$d/index/ml-commons/index.html"
touch "$d/work/dist/ml_commons-0.0.5-py3-none-any.whl" "$d/work/dist/ml_commons-0.0.5.tar.gz" "$d/work/dist/Other.Pkg-1.2.tar.gz"
echo "Other.Pkg-1.2.tar.gz" > "$d/409"

run() { (cd "$d/work" && PATH="$d/bin:$PATH" STUB="$d" TOKEN=jwt URL=https://packages.example/simple/ TOOLS_INDEX=https://token@packages.example/simple/ bash -eo pipefail -c "$prog") > "$d/out" 2>&1; }

run || { cat "$d/out"; echo "FAIL: expected success"; exit 1; }
grep -q 'skip ml_commons-0.0.5-py3-none-any.whl: already on' "$d/out" || { cat "$d/out"; echo "FAIL: existing wheel not skipped"; exit 1; }
grep -q 'skip Other.Pkg-1.2.tar.gz: 409' "$d/out" || { cat "$d/out"; echo "FAIL: 409 not treated as uploaded"; exit 1; }
grep -qF 'https://packages.example/simple/other-pkg/' "$d/curl.log" || { cat "$d/curl.log"; echo "FAIL: project name not PEP 503 normalized"; exit 1; }
[ "$(wc -l < "$d/uvx.log")" -eq 2 ] || { cat "$d/uvx.log"; echo "FAIL: want 2 uploads (sdist + Other.Pkg)"; exit 1; }
grep -q -- '--skip-existing' "$d/uvx.log" && { echo "FAIL: --skip-existing passed to twine"; exit 1; }
grep -qv -- '--from twine==' "$d/uvx.log" && { cat "$d/uvx.log"; echo "FAIL: twine not pinned"; exit 1; }
grep -qv -- '--default-index https://token@packages.example/simple/' "$d/uvx.log" && { cat "$d/uvx.log"; echo "FAIL: twine not from nora"; exit 1; }

: > "$d/uvx.log"; echo "ml_commons-0.0.5.tar.gz" > "$d/500"
if run; then cat "$d/out"; echo "FAIL: a 500 on upload must fail the step"; exit 1; fi
echo "pypi-upload: OK"
