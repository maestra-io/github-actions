#!/usr/bin/env bash
# Tests for pr-checks/: check-encoding.py (UTF-8 passes, cp1251/UTF-16 fail, other
# extensions and deleted paths are ignored, no files = whole tree) and the
# kustomize entry-point listing used by pr-checks.yml.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
enc="$root/pr-checks/check-encoding.py"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
check() { # name expected-exit command...
	local name=$1 want=$2; shift 2
	local got=0
	"$@" >"$work/out" 2>&1 || got=$?
	if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name: exit $got, want $want"; cat "$work/out"; fail=1; fi
}

cd "$work"
git init -q .
printf 'class A {} // ascii\n' > a.cs
printf '{"k": "\xd0\xbf\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82"}\n' > utf8.json
printf '// \xcf\xf0\xe8\xe2\xe5\xf2\n' > cp1251.cs
printf '\xff\xfeh\x00i\x00' > utf16.txt
printf '\xcf\xf0\xe8\xe2\xe5\xf2\n' > cp1251.md
git add a.cs utf8.json

check "ascii and utf-8 pass"           0 python3 -I "$enc" txt,json,cs a.cs utf8.json
check "cp1251 .cs fails"               1 python3 -I "$enc" txt,json,cs a.cs cp1251.cs
check "utf-16 .txt fails"              1 python3 -I "$enc" txt,json,cs utf16.txt
check "other extension ignored"        0 python3 -I "$enc" txt,json,cs cp1251.md
check "deleted path ignored"           0 python3 -I "$enc" txt,json,cs gone.cs
check "extension match is case-blind"  1 python3 -I "$enc" CS cp1251.cs
check "no files = tracked files only"  0 python3 -I "$enc" txt,json,cs
git add cp1251.cs
check "tracked cp1251 fails whole-tree" 1 python3 -I "$enc" txt,json,cs
grep -q "cp1251.cs: invalid continuation byte" "$work/out" && echo "ok   names the file" || { echo "FAIL names the file"; fail=1; }

# kustomize entry points: overlays/* directories with a kustomization file.
mkdir -p kustomization/svc/base kustomization/svc/overlays/omega kustomization/other/overlays/omicron kustomization/svc/overlays/omega/patches
touch kustomization/svc/base/kustomization.yaml kustomization/svc/overlays/omega/kustomization.yaml \
	kustomization/other/overlays/omicron/kustomization.yml kustomization/svc/overlays/omega/patches/p.yaml
got=$(bash "$root/pr-checks/kustomize-entry-points.sh" kustomization | tr '\n' ' ')
want="kustomization/other/overlays/omicron kustomization/svc/overlays/omega "
[ "$got" = "$want" ] && echo "ok   kustomize entry points" || { echo "FAIL kustomize entry points: '$got', want '$want'"; fail=1; }

exit $fail
