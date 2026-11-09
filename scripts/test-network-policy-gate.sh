#!/usr/bin/env bash
# Tests for pr-checks/check-network-policy.py on ci/fixtures/network-policy (the
# universal-channel-http-sender pilot): the omicron block renders, passes kubeconform and the
# broad gate; a block without ports fails with the chart's schema text; a block in overlays/omega
# is rejected naming the file; no block = one line; an unpinned chart version is refused; a
# stub helm that renders a broad / invalid policy is caught by the broad gate / kubeconform.
#
# Real kustomize, helm and kubeconform (downloaded at the workflow's pins when not on PATH) and
# the real commons-app chart: from $CHARTS_DIR when it holds commons-app-<version>.tgz, else
# pulled from ECR after an `aws ecr get-login-password` login (the runner's instance role) — the
# same path the pr-checks step takes, so a runner without ECR read fails here first.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
gate="$root/pr-checks/check-network-policy.py"
eps="$root/pr-checks/kustomize-entry-points.sh"
wf="$root/.github/workflows/pr-checks.yml"
fixture="$root/ci/fixtures/network-policy/kustomization"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
pin() { sed -n "s/^  $1: //p" "$wf"; }

# tool <env var> <name> <url> <sha256> <tar member> [strip]
tool() {
	local var=$1 name=$2 url=$3 sha=$4 member=$5 strip=${6:-0}
	if command -v "$name" >/dev/null; then export "$var=$(command -v "$name")"; return; fi
	curl -fsSL -o "$work/$name.tgz" "$url"
	echo "$sha  $work/$name.tgz" | sha256sum -c - >/dev/null
	tar -xzf "$work/$name.tgz" -C "$work" --strip-components="$strip" "$member"
	export "$var=$work/$name"
}
tool KUSTOMIZE kustomize "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F$(pin KUSTOMIZE_VERSION)/kustomize_$(pin KUSTOMIZE_VERSION)_linux_amd64.tar.gz" "$(pin KUSTOMIZE_SHA256)" kustomize
tool HELM helm "https://get.helm.sh/helm-$(pin HELM_VERSION)-linux-amd64.tar.gz" "$(pin HELM_SHA256)" linux-amd64/helm 1
tool KUBECONFORM kubeconform "https://github.com/yannh/kubeconform/releases/download/$(pin KUBECONFORM_VERSION)/kubeconform-linux-amd64.tar.gz" "$(pin KUBECONFORM_SHA256)" kubeconform
echo "kustomize $("$KUSTOMIZE" version), helm $("$HELM" version --template '{{.Version}}'), kubeconform $("$KUBECONFORM" -v)"

version=$(sed -n 's/^ *version: "\(.*\)"/\1/p' "$fixture/base/helm-release-app.yaml")
charts=${CHARTS_DIR:-$work/charts}
if [ ! -f "$charts/commons-app-$version.tgz" ]; then
	registry=$(pin ECR_REGISTRY)
	aws ecr get-login-password --region "$(cut -d. -f4 <<<"$registry")" | "$HELM" registry login --username AWS --password-stdin "$registry" \
		|| { echo "FAIL ECR login: no AWS credentials (set CHARTS_DIR to a dir holding commons-app-$version.tgz to test offline)"; exit 1; }
	echo "chart commons-app-$version pulled from ECR by the gate"
fi

check() { # name expected-exit grep-pattern command...
	local name=$1 want=$2 pat=$3; shift 3
	local got=0
	"$@" >"$work/out" 2>&1 || got=$?
	if [ "$got" = "$want" ] && grep -qE -- "$pat" "$work/out"; then echo "ok   $name"; else echo "FAIL $name: exit $got (want $want), output:"; cat "$work/out"; fail=1; fi
}
gate() { # <tree> [gate args]
	local tree=$1; shift
	local -a points=()
	while IFS= read -r ep; do points+=("$ep"); done < <(cd "$work" && bash "$eps" "$tree")
	(cd "$work" && python3 -I "$gate" --kustomize-path "$tree" --charts-dir "$charts" "$@" "${points[@]}")
}
tree() { rm -rf "${work:?}/$1"; cp -r "$fixture" "$work/$1"; }

tree k
check "pilot block renders, 1 policy, kubeconform + broad gate" 0 "ok   k/overlays/omicron: .* commons-app $version: 1 Cilium policies, kubeconform ok, broad gate ok" gate k
grep -q "1 release(s) rendered" "$work/out" && echo "ok   summary counts the release" || { echo "FAIL summary"; fail=1; }

tree k
sed -i.bak '/ports: \[8080\]/d' "$work/k/overlays/omicron/patch-app.yaml"
check "ports missing: chart schema text in the error" 1 "missing property 'ports'" gate k
grep -q "^::error file=k/overlays/omicron/patch-app.yaml::" "$work/out" && echo "ok   error names the patch file" || { echo "FAIL error file"; fail=1; }

tree k
sed -i.bak 's/- to: {preset: dragonfly}/- to: {cidr: 10.0.0.0\/8}/' "$work/k/overlays/omicron/patch-app.yaml"
check "raw cidr: schema rejects it" 1 "additional properties 'cidr' not allowed" gate k

tree k
printf '    networkPolicy:\n      enabled: true\n      egress:\n        - to: {preset: dragonfly}\n' >>"$work/k/overlays/omega/patch-app.yaml"
check "omega block rejected, file named" 1 "^::error file=k/overlays/omega/patch-app.yaml::networkPolicy in overlay omega: .* only in overlays/\{omicron\}" gate k
grep -q "dragonfly-v2.yaml" "$work/out" && { echo "FAIL dragonfly's own key listed as a culprit"; fail=1; } || echo "ok   dragonfly key not blamed"
grep -q "^ok   k/overlays/omicron" "$work/out" && echo "ok   omicron still rendered" || { echo "FAIL omicron skipped"; fail=1; }

tree k
sed -i.bak '/networkPolicy:/,$d' "$work/k/overlays/omicron/patch-app.yaml"
check "no block anywhere: one line, exit 0" 0 "^no networkPolicy block in a commons-app/postgres HelmRelease under k$" gate k

tree k
sed -i.bak "s/version: \"$version\"/version: \">=18.0.0\"/" "$work/k/base/helm-release-app.yaml"
check "unpinned chart version refused" 1 "version '>=18.0.0' is not an exact pin" gate k

# Job summary: the chart's text lands in $GITHUB_STEP_SUMMARY.
tree k
sed -i.bak '/ports: \[8080\]/d' "$work/k/overlays/omicron/patch-app.yaml"
: >"$work/summary.md"
GITHUB_STEP_SUMMARY="$work/summary.md" gate k >/dev/null 2>&1 || true
grep -q "missing property 'ports'" "$work/summary.md" && echo "ok   job summary carries the chart error" || { echo "FAIL job summary"; cat "$work/summary.md"; fail=1; }

# Stub helm: the rendered policies decide. A world egress without ports trips the broad gate
# (V2); an unknown field trips kubeconform -strict.
cat >"$work/stub-helm" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  pull) : ;;
  template) cat "$STUB_RENDER" ;;
esac
EOF
chmod +x "$work/stub-helm"
cat >"$work/broad.yaml" <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: x-netpol, namespace: universal-channel-http-sender}
spec:
  endpointSelector: {matchLabels: {app: x}}
  egress:
    - toEntities: [world]
EOF
cat >"$work/invalid.yaml" <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: x-netpol, namespace: universal-channel-http-sender}
spec:
  endpointSelector: {matchLabels: {app: x}}
  egres:
    - toEntities: [world]
EOF
tree k
HELM="$work/stub-helm" STUB_RENDER="$work/broad.yaml" gate k >"$work/out" 2>&1 && got=0 || got=$?
if [ "$got" = 1 ] && grep -q "x-netpol:V2 — egress: \['world'\] without ports" "$work/out"; then echo "ok   broad policy: netpol-broad-gate V2"; else echo "FAIL broad policy: exit $got"; cat "$work/out"; fail=1; fi
HELM="$work/stub-helm" STUB_RENDER="$work/invalid.yaml" gate k >"$work/out" 2>&1 && got=0 || got=$?
if [ "$got" = 1 ] && grep -q "fail the Cilium CRD schema" "$work/out" && grep -q "egres" "$work/out"; then echo "ok   invalid field: kubeconform -strict"; else echo "FAIL invalid field: exit $got"; cat "$work/out"; fail=1; fi

# No overlays at all: nothing to pass, exit 0.
mkdir -p "$work/flat/base"
check "tree without overlays" 0 "^no networkPolicy block" bash -c "cd '$work' && python3 -I '$gate' --kustomize-path flat --charts-dir '$charts'"

exit $fail
