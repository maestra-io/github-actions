#!/usr/bin/env bash
# nora-tool.sh <tool> plan|install: one toolchain from nora (issues-maestra#1649) in place of the
# vendor download of actions/setup-go, actions/setup-node, actions/setup-python, astral-sh/setup-uv,
# hashicorp/setup-terraform and azure/setup-helm. <tool>: go | node | python | uv | terraform | helm.
# The archives and their sha256 are pinned in setup-<tool>-nora/versions.txt (<version> <sha256>
# [<release tag>]); the version spec (TOOL_VERSION, the setup action's syntax: empty or latest = the
# newest pin, N / N.x, N.M / N.M.x = the newest pin of that line, N.M.P = exactly that pin; go also
# TOOL_VERSION_FILE, a go.mod whose toolchain / go line is a floor within its N.M) picks one pin.
# Where nora gets the archive:
#   go, node, helm  raw src/<vendor host>/<path>, uploaded by maestra-io/dockerfiles
#                   .github/raw-uploads/{go,node,helm}.txt (same sha256)
#   python, uv      nora's GitHub Releases proxy (python-build-standalone, astral-sh/uv)
#   terraform       nora's releases.hashicorp.com proxy
# The archive is checked against the pin and unpacked into the runner tool cache
# ($RUNNER_TOOL_CACHE/<name>/<version>/<arch>, as the setup actions lay it out, with the
# <arch>.complete marker), whose bin goes on PATH. The unpacked tree is pinned too (the last column of
# versions.txt: tree_digest below over what the pinned archive unpacks to). A version already complete
# there (the runner image's, or an earlier job's on a reused instance) is used, with nothing fetched,
# only when its tree is that pin; any other tree (a tampered binary, an added file, a package
# installed into it, the runner image's own build) is reinstalled from the verified archive. A freshly
# unpacked tree that is not the pin fails the step.
# plan: writes version and cache-key (empty when nothing is to fetch) to $GITHUB_OUTPUT.
# install: NORA_TOOL_CACHE_DIR = archives restored from the runner cache (RunsOn Magic Cache):
# one is used only when its sha256 is the pin, anything else is deleted and fetched from nora;
# a fetched archive is kept there and save=true written for the cache save.
# NORA_TOOL_RESOLVE_ONLY=1 prints the resolved version and stops (scripts/test-nora-tool.sh).
# tree <archive>: prints the tree pin of a verified archive (unpacked as install does; GNU tools,
# linux): how the last column of versions.txt is made.
set -euo pipefail
tool=${1:?tool} mode=${2:?plan|install|tree}
here=$(cd "$(dirname "$0")" && pwd)
list="$here/../setup-$tool-nora/versions.txt"
fail() { echo "::error::setup-$tool-nora: $*" >&2; exit 1; }
umask 022 # the exec bits of the unpacked tree are part of its pin

# unpack <archive> <dir>: the archive's toolchain into <dir> (created), as install lays it out
unpack() {
  mkdir -p "$2"
  case "$tool" in
    terraform) python3 -I -m zipfile -e "$1" "$2" && chmod +x "$2/terraform" ;;
    helm) tar -xzf "$1" -C "$2" --strip-components=1 linux-amd64/helm ;;
    *) tar -xzf "$1" -C "$2" --strip-components=1 ;;
  esac || return 1
  # python-build-standalone has python3 / pip3; setup-python's builds also answer to python / pip
  if [ "$tool" = python ]; then
    [ -e "$2/bin/python" ] || ln -s python3 "$2/bin/python"
    [ -e "$2/bin/pip" ] || [ ! -e "$2/bin/pip3" ] || ln -s pip3 "$2/bin/pip"
  fi
}
# tree_digest <dir>: sha256 over every entry's type, path and symlink target, the owner-exec bit of
# every file and the sha256 of every file's content. Anything added, removed, rewritten or made
# executable changes it; mtimes and owners do not.
tree_digest() {
  ( cd "$1" && LC_ALL=C find . -mindepth 1 -printf '%y %p %l\n' | LC_ALL=C sort \
      && LC_ALL=C find . -type f -perm -u+x -printf 'x %p\n' | LC_ALL=C sort \
      && LC_ALL=C find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum ) | sha256sum | cut -d' ' -f1
}
if [ "$mode" = tree ]; then
  a=${3:?archive}; t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  unpack "$a" "$t/x" || fail "$a: unpacking failed"
  tree_digest "$t/x"; exit 0
fi
[ -f "$list" ] || fail "no pin file $list"

listed() { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$list" | awk '{ print $1 }' | sort -V; }
pin() { sed -e 's/#.*//' "$list" | awk -v v="$1" -v c="$2" '$1 == v { print (c == "NF" ? $NF : $c) }'; }

# setup-* version spec → one pinned version
resolve_spec() {
  local s=${1#v} p
  case "$s" in
    ''|latest|'*') p=$(listed | tail -1) ;;
    *) if [[ $s =~ ^([0-9]+)(\.x)?$ ]]; then p=$(listed | awk -F. -v M="${BASH_REMATCH[1]}" '$1 == M' | tail -1)
       elif [[ $s =~ ^([0-9]+)\.([0-9]+)(\.x)?$ ]]; then p=$(listed | awk -F. -v M="${BASH_REMATCH[1]}" -v m="${BASH_REMATCH[2]}" '$1 == M && $2 == m' | tail -1)
       elif [[ $s =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then p=$(listed | grep -Fx "$s" || true)
       else fail "version '$1': only latest, N, N.x, N.M, N.M.x or an exact version are served"
       fi ;;
  esac
  [ -n "$p" ] || fail "no pinned version for '$1' in setup-$tool-nora/versions.txt: add it there (and, for go / node / helm, to maestra-io/dockerfiles .github/raw-uploads/$tool.txt first)"
  echo "$p"
}
# go.mod: `toolchain goX.Y.Z`, else `go X.Y[.Z]` (what setup-go reads; a `//` comment after either is
# ignored) — the newest pin of X.Y at or above it
resolve_go_mod() {
  local gm=$1 v M m p
  [ -f "$gm" ] || fail "go-version-file $f not found"
  v=$(sed -e 's|//.*||' "$gm" | sed -n 's/^[[:space:]]*toolchain[[:space:]]*go\([0-9][0-9.]*\)[[:space:]]*$/\1/p' | head -1)
  [ -n "$v" ] || v=$(sed -e 's|//.*||' "$gm" | sed -n 's/^[[:space:]]*go[[:space:]]*\([0-9][0-9.]*\)[[:space:]]*$/\1/p' | head -1)
  [[ $v =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]] || fail "$gm names no Go version"
  M=${BASH_REMATCH[1]} m=${BASH_REMATCH[2]} p=${BASH_REMATCH[4]:-0}
  v=$(listed | awk -F. -v M="$M" -v m="$m" -v p="$p" '$1 == M && $2 == m && $3 >= p' | tail -1)
  [ -n "$v" ] || fail "no pinned Go $M.$m.x at or above $gm's ${M}.${m}.${p} in setup-go-nora/versions.txt"
  echo "$v"
}

if [ "$tool" = go ] && [ -z "${TOOL_VERSION:-}" ] && [ -n "${TOOL_VERSION_FILE:-}" ]; then
  v=$(resolve_go_mod "$TOOL_VERSION_FILE")
else
  v=$(resolve_spec "$(head -1 <<<"${TOOL_VERSION:-}" | tr -d '[:space:]')")
fi
if [ "${NORA_TOOL_RESOLVE_ONLY:-}" = 1 ]; then echo "$v"; exit 0; fi
[ "$(uname -m)" = x86_64 ] || fail "only linux x64 archives are pinned (this runner: $(uname -s) $(uname -m))"
sum=$(pin "$v" 2)
tree=$(pin "$v" NF)
[[ $tree =~ ^[0-9a-f]{64}$ && $tree != "$sum" ]] || fail "$v has no tree pin (last column) in versions.txt"
base="${NORA_URL:-https://packages.maestra.io}"; base=${base%/}
# the session exchange sends the job's OIDC token: never over plain http
[[ $base == https://* ]] || fail "url '$base' is not https"
arch=x64
case "$tool" in
  go) name=go; file="go$v.linux-amd64.tar.gz"; url="$base/raw/src/go.dev/dl/$file" ;;
  node) name=node; file="node-v$v-linux-x64.tar.gz"; url="$base/raw/src/nodejs.org/dist/v$v/$file" ;;
  helm) name=helm; file="helm-v$v-linux-amd64.tar.gz"; url="$base/raw/src/get.helm.sh/$file" ;;
  python) name=Python; tag=$(pin "$v" 3); [ -n "$tag" ] || fail "$v has no python-build-standalone release tag in versions.txt"
    file="cpython-$v+$tag-x86_64-unknown-linux-gnu-install_only.tar.gz"
    url="$base/github/astral-sh/python-build-standalone/releases/download/$tag/$file" ;;
  uv) name=uv arch=x86_64; file=uv-x86_64-unknown-linux-gnu.tar.gz; url="$base/github/astral-sh/uv/releases/download/$v/$file" ;;
  terraform) name=terraform; file="terraform_${v}_linux_amd64.zip"; url="$base/hashicorp/terraform/$v/$file" ;;
  *) fail "unknown tool $tool" ;;
esac

tc="${RUNNER_TOOL_CACHE:-/opt/hostedtoolcache}"
if ! { mkdir -p "$tc/$name" 2>/dev/null && [ -w "$tc/$name" ]; }; then tc="${RUNNER_TEMP:-/tmp}/nora-tools"; mkdir -p "$tc/$name"; fi
dir="$tc/$name/$v/$arch"
bin=$dir
case "$tool" in go|node|python) bin=$dir/bin ;; esac
exe=$bin/$tool; [ "$tool" != python ] || exe=$bin/python3
# a tool-cache entry counts only with its marker AND its executable (plan: then no archive is
# restored); install also requires its tree to be the pin before anything in it runs
installed() { [ -f "$dir.complete" ] && [ -x "$exe" ]; }

if [ "$mode" = plan ]; then
  key=""
  installed || key="nora-tool-$tool-$v-linux-$arch-${sum:0:16}"
  { echo "version=$v"; echo "cache-key=$key"; } >> "$GITHUB_OUTPUT"
  echo "setup-$tool-nora: $tool $v, cache key '${key}'"
  exit 0
fi
[ "$mode" = install ] || fail "mode $mode"

# one cold install of a version at a time on a host (jobs sharing a tool cache)
if command -v flock >/dev/null; then exec 9>"$tc/$name/.$v-$arch.lock"; flock 9; fi
got_tree=""
if installed; then got_tree=$(tree_digest "$dir") || got_tree=unreadable; fi
if [ "$got_tree" = "$tree" ]; then
  echo "setup-$tool-nora: $tool $v already in the tool cache ($dir, tree sha256 $tree), nothing fetched"
  echo "source=tool-cache" >> "$GITHUB_OUTPUT"
else
  [ -z "$got_tree" ] || echo "::warning::setup-$tool-nora: $dir is not the pinned tree (tree sha256 $got_tree, versions.txt pins $tree): reinstalling it from the verified archive"
  cache="${NORA_TOOL_CACHE_DIR:-}"
  tmp="${cache:-${RUNNER_TEMP:-/tmp}/nora-tool-$tool}"; mkdir -p "$tmp"
  f="$tmp/$file"
  # A cached archive is another copy of an executable: used only when its sha256 is the pin.
  if [ -n "$cache" ] && [ -s "$f" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$sum" ]; then
    echo "setup-$tool-nora: $tool $v archive from the runner cache (sha256 $sum), nothing fetched from nora"
    echo "source=runner-cache" >> "$GITHUB_OUTPUT"
  else
    # (a rejected cached archive: the fetched one is saved over it, save=true below)
    [ ! -e "$f" ] || { echo "::warning::setup-$tool-nora: cached $file is not the sha256 pin, fetching it from nora"; rm -f "$f"; }
    # shellcheck source=SCRIPTDIR/../nora-session/nora-session.sh
    . "$here/../nora-session/nora-session.sh"
    token=$(nora_token "$base" "${NORA_AUDIENCE:-packages.maestra.io}") || fail "no nora token (the job needs permissions: id-token: write)"
    echo "::add-mask::$token"
    # the credential reaches curl as a config on stdin, never on its command line
    printf 'user = "token:%s"\n' "$token" | curl -fsS --retry 3 --connect-timeout 15 --speed-limit 1024 --speed-time 60 -K - -o "$f" "$url" \
      || { rm -f "$f"; fail "GET $url failed"; }
    got=$(sha256sum "$f" | cut -d' ' -f1)
    [ "$got" = "$sum" ] || { rm -f "$f"; fail "$file from $url: sha256 $got, versions.txt pins $sum"; }
    echo "setup-$tool-nora: $tool $v fetched from $url (sha256 $sum)"
    echo "source=nora" >> "$GITHUB_OUTPUT"
    [ -z "$cache" ] || echo "save=true" >> "$GITHUB_OUTPUT"
  fi
  # unpacked next to its final place, moved in whole, then marked complete
  rm -rf "$dir" "$dir.nora" "$dir.complete"
  unpack "$f" "$dir.nora" || { rm -rf "$dir.nora"; fail "$file: unpacking failed"; }
  [ -n "${cache:-}" ] || rm -f "$f"
  got_tree=$(tree_digest "$dir.nora")
  [ "$got_tree" = "$tree" ] || { rm -rf "$dir.nora"; fail "$file unpacked to tree sha256 $got_tree, versions.txt pins $tree"; }
  mv "$dir.nora" "$dir"
  touch "$dir.complete"
  echo "setup-$tool-nora: $tool $v into $dir (tree sha256 $tree)"
fi
exec 9>&-
echo "$bin" >> "$GITHUB_PATH"
export PATH="$bin:$PATH"
{ echo "version=$v"; echo "dir=$dir"; echo "path=$bin/$tool"; } >> "$GITHUB_OUTPUT"
case "$tool" in
  go) # setup-go: GOPATH/bin on PATH; the module / build cache paths for the cache step. The probes
    # and later steps run the pinned go itself, never a toolchain a go.mod / go.work names: that one
    # would come from proxy.golang.org (go-version-file already resolves to its toolchain line).
    export GOTOOLCHAIN=local; echo "GOTOOLCHAIN=local" >> "$GITHUB_ENV"
    echo "$(go env GOPATH)/bin" >> "$GITHUB_PATH"
    { echo "gomodcache=$(go env GOMODCACHE)"; echo "gocache=$(go env GOCACHE)"; } >> "$GITHUB_OUTPUT"
    go version ;;
  node) node --version ;;
  python) # (python / pip links: unpack)
    { echo "pythonLocation=$dir"; echo "Python_ROOT_DIR=$dir"; echo "Python2_ROOT_DIR=$dir"; echo "Python3_ROOT_DIR=$dir"
      echo "PKG_CONFIG_PATH=$dir/lib/pkgconfig"; echo "LD_LIBRARY_PATH=$dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"; } >> "$GITHUB_ENV"
    "$bin/python" --version ;;
  uv) echo "uvx-path=$bin/uvx" >> "$GITHUB_OUTPUT"; uv --version ;;
  terraform) CHECKPOINT_DISABLE=1 terraform version ;;
  helm) helm version --short ;;
esac
