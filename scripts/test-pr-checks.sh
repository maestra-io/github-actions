#!/usr/bin/env bash
# Tests for pr-checks/: check-encoding.py (UTF-8 passes, cp1251/UTF-16 fail, other
# extensions and deleted paths are ignored, no files = whole tree), the kustomize
# entry-point listing used by pr-checks.yml, and check-image-signatures.py with a stub
# kyverno (no network).
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

# check-image-signatures.py: only new refs the policy covers, and the verdict.
sig="$root/pr-checks/check-image-signatures.py"
good=public.ecr.aws/gravitational/tbot-distroless@sha256:$(printf 'a%.0s' {1..64})
bad=public.ecr.aws/gravitational/tbot-distroless@sha256:$(printf 'b%.0s' {1..64})
other=docker.io/library/alpine@sha256:$(printf 'c%.0s' {1..64})
cat > policy.yaml <<EOF
imageReferences:
  - "public.ecr.aws/gravitational/tbot-distroless@*"
  - "public.ecr.aws/gravitational/tbot-distroless:*"
EOF
printf 'image: %s\n' "$good" > base.yaml
{ printf 'image: %s\n' "$good"; printf '  image: "%s"\n' "${bad/@/:18.11.8@}"; printf 'image: %s\n' "$other"; } > head.yaml
got=$(python3 -I "$sig" list policy.yaml head.yaml base.yaml)
[ "$got" = "$bad" ] && echo "ok   list: new covered ref, tag dropped" || { echo "FAIL list: '$got', want '$bad'"; fail=1; }
# A file, not $(...): a lone newline would pass here and still trigger the Kyverno download.
python3 -I "$sig" list policy.yaml base.yaml base.yaml > listed
[ ! -s listed ] && echo "ok   list: nothing new, empty output" || { echo "FAIL list nothing new: $(wc -c < listed) bytes"; fail=1; }

# Stub kyverno: refs are sorted, so image-0 is $good (fails only an audit rule) and image-1
# is $bad (fails an enforcing rule).
cat > stub-kyverno <<'EOF'
#!/usr/bin/env bash
echo "Applying 1 policy rule(s)..."
cat <<'JSON'
{"kind": "ClusterReport", "results": [
  {"result": "fail", "rule": "teleport", "message": "no signatures found", "resources": [{"name": "image-1"}]},
  {"result": "fail", "rule": "teleport-tag-refs", "message": "audit only", "resources": [{"name": "image-0"}]},
  {"result": "pass", "rule": "teleport", "resources": [{"name": "image-0"}]}
]}
JSON
exit 1
EOF
printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 2\n' > broken-kyverno
printf '#!/usr/bin/env bash\necho "not a report"\nexit 0\n' > mute-kyverno
chmod +x stub-kyverno broken-kyverno mute-kyverno
printf '%s\n%s\n' "$bad" "$good" > images
sig_verify() { python3 -I "$sig" verify policy.yaml "$@" < images; }
check "rejected image warns"                 0 sig_verify ./stub-kyverno
grep -q "^::warning title=image signature::$bad would be denied" "$work/out" && echo "ok   warning annotation" || { echo "FAIL warning annotation"; fail=1; }
check "rejected image fails with --enforce"  1 sig_verify ./stub-kyverno --enforce
grep -q "^::error title=image signature::$bad would be denied" "$work/out" && echo "ok   error annotation" || { echo "FAIL error annotation"; fail=1; }
grep -q "^ok   $good" "$work/out" && echo "ok   audit-only failure is not a rejection" || { echo "FAIL audit-only failure"; fail=1; }
check "kyverno crash never fails, --enforce" 0 sig_verify ./broken-kyverno --enforce
check "no report never fails, --enforce"     0 sig_verify ./mute-kyverno --enforce
check "no kyverno binary never fails"        0 sig_verify ./missing-kyverno --enforce
: > images
check "no images: kyverno not started"       0 sig_verify ./missing-kyverno --enforce

exit $fail
