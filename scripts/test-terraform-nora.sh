#!/usr/bin/env bash
# terraform-nora/terraform-nora.sh with a stub `curl` on PATH: the CLI config it
# writes (mirror, direct, helper, ~/.terraformrc credentials kept, filesystem
# mirror variant), TF_CLI_CONFIG_FILE exported, the credentials helper answering
# only its host, and the refusals (no id-token permission, provider_installation
# already in ~/.terraformrc). When terraform is on PATH, it must parse the config.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/../terraform-nora/terraform-nora.sh"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin"
cat > "$root/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Asserts the OIDC request shape, then answers like the Actions token service.
[[ " $* " == *" -H Authorization: bearer req-token "* ]] || { echo "bad auth header: $*" >&2; exit 22; }
[[ "${*: -1}" == "https://idtok.example/x?api-version=2.0&audience=packages.maestra.io" ]] || { echo "bad url: ${*: -1}" >&2; exit 22; }
echo '{"value":"eyJ.stub.jwt"}'
STUB
chmod +x "$root/bin/curl"

fail() { echo "FAIL: $*" >&2; exit 1; }
run() { # run in a fresh HOME/RUNNER_TEMP; extra env as args
  local case_dir="$root/$1"; shift
  mkdir -p "$case_dir/home" "$case_dir/tmp"
  env -i PATH="$root/bin:$PATH" HOME="$case_dir/home" RUNNER_TEMP="$case_dir/tmp" \
    GITHUB_ENV="$case_dir/env" NORA_URL=https://packages.maestra.io/ NORA_AUDIENCE=packages.maestra.io \
    FS_MIRROR_PATH= FS_MIRROR_INCLUDE= \
    ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?api-version=2.0' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token \
    "$@" bash "$script" > "$case_dir/out" 2>&1
}

# 1. default: mirror + direct + helper; setup-terraform's credentials carried over.
mkdir -p "$root/plain/home"
printf 'credentials "app.terraform.io" {\n  token = "tfc"\n}\n' > "$root/plain/home/.terraformrc"
run plain || fail "plain: $(cat "$root/plain/out")"
cfg="$root/plain/tmp/terraform-nora/terraform.tfrc"
[ "$(cat "$root/plain/env")" = "TF_CLI_CONFIG_FILE=$cfg" ] || fail "TF_CLI_CONFIG_FILE not exported"
grep -q 'url     = "https://packages.maestra.io/terraform/"' "$cfg" || fail "mirror url"
grep -q 'include = \["registry.terraform.io/\*/\*"\]' "$cfg" || fail "mirror include"
grep -q 'exclude = \["registry.terraform.io/\*/\*"\]' "$cfg" || fail "direct exclude"
grep -q 'credentials_helper "nora" {}' "$cfg" || fail "helper block"
grep -q 'token = "tfc"' "$cfg" || fail "terraformrc credentials dropped"
! grep -q filesystem_mirror "$cfg" || fail "unexpected filesystem_mirror"
helper="$root/plain/home/.terraform.d/plugins/terraform-credentials-nora"
out=$(PATH="$root/bin:$PATH" ACTIONS_ID_TOKEN_REQUEST_URL='https://idtok.example/x?api-version=2.0' \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token "$helper" get packages.maestra.io)
[ "$out" = '{"token":"eyJ.stub.jwt"}' ] || fail "helper get: $out"
[ "$("$helper" get app.terraform.io)" = '{}' ] || fail "helper answered another host"
! "$helper" store packages.maestra.io </dev/null 2>/dev/null || fail "helper store must fail"

# 2. filesystem mirror for a private namespace: excluded from the network mirror.
run fs FS_MIRROR_PATH=/tmp/m FS_MIRROR_INCLUDE='registry.terraform.io/mindbox-private/*, ' \
  || fail "fs: $(cat "$root/fs/out")"
cfg="$root/fs/tmp/terraform-nora/terraform.tfrc"
grep -q 'path    = "/tmp/m"' "$cfg" || fail "fs path"
[ "$(grep -c '"registry.terraform.io/mindbox-private/\*"\]' "$cfg")" -eq 2 ] || fail "fs include/exclude: $(cat "$cfg")"

# 3. refusals.
mkdir -p "$root/noid"
env -i PATH="$PATH" HOME="$root/noid" RUNNER_TEMP="$root/noid" GITHUB_ENV="$root/noid/env" \
  NORA_URL=https://packages.maestra.io NORA_AUDIENCE=a FS_MIRROR_PATH= FS_MIRROR_INCLUDE= \
  bash "$script" >"$root/noid/out" 2>&1 && fail "no id-token must fail"
grep -q 'id-token: write' "$root/noid/out" || fail "no id-token message"
mkdir -p "$root/dup/home"
printf 'provider_installation {\n  direct {}\n}\n' > "$root/dup/home/.terraformrc"
run dup && fail "existing provider_installation must fail"
grep -q 'already has provider_installation' "$root/dup/out" || fail "dup message"
run fsnoinc FS_MIRROR_PATH=/tmp/m && fail "fs path without include must fail"

# 4. terraform itself accepts the files (when installed).
if command -v terraform >/dev/null; then
  for c in plain fs; do
    TF_CLI_CONFIG_FILE="$root/$c/tmp/terraform-nora/terraform.tfrc" terraform version 2>&1 \
      | grep -qi 'error\|warning' && fail "terraform rejects the $c config"
  done
fi
echo "terraform-nora: all cases passed"
