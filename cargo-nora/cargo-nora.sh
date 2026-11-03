#!/usr/bin/env bash
# Routes cargo through nora and writes the docker-token output (see action.yml).
# Env: NORA_URL, NORA_AUDIENCE, CARGO_HOME (default ~/.cargo); RUNNER_TEMP,
# GITHUB_OUTPUT and the runner's ACTIONS_ID_TOKEN_REQUEST_{URL,TOKEN}.
set -euo pipefail

: "${ACTIONS_ID_TOKEN_REQUEST_URL:?no GitHub OIDC token available: the job needs permissions: id-token: write}"
url="${NORA_URL%/}"
dir="${RUNNER_TEMP}/cargo-nora"
mkdir -p "$dir"

# token-from-stdout provider: cargo runs it each time it needs the credential.
helper="$dir/token"
cat > "$helper" <<SH
#!/usr/bin/env bash
set -euo pipefail
token=\$(curl -fsS --retry 3 -H "Authorization: bearer \${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \\
  "\${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=$NORA_AUDIENCE" | jq -r .value)
[ -n "\$token" ] && [ "\$token" != null ] || { echo "cargo-nora: no OIDC token" >&2; exit 1; }
printf 'Basic %s\n' "\$(printf 'token:%s' "\$token" | base64 | tr -d '\\n')"
SH
chmod +x "$helper"

cargo_home="${CARGO_HOME:-$HOME/.cargo}"
mkdir -p "$cargo_home"
cat >> "$cargo_home/config.toml" <<TOML

# cargo-nora (maestra-io/github-actions): crates.io through $url
[source.crates-io]
replace-with = "nora"
[source.nora]
registry = "sparse+$url/cargo/index/"
[registries.nora]
index = "sparse+$url/cargo/index/"
credential-provider = ["cargo:token-from-stdout", "$helper"]
TOML

token=$("$helper")
echo "::add-mask::$token"
echo "::add-mask::${token#Basic }"
echo "docker-token=$token" >> "$GITHUB_OUTPUT"
echo "cargo: crates from $url/cargo (config $cargo_home/config.toml)"
