#!/usr/bin/env python3
"""Gate for the `networkPolicy` values block of a service (issues-maestra#1714, 1c).

Kargo pushes a release straight to fluxcd main, and a HelmRelease whose values the chart's
schema or templates reject blocks every later promotion of that service. This runs on the
pull request what Flux runs after the merge, for every kustomize entry point given:

  kustomize build <overlay>  ->  HelmRelease on chart commons-app | postgres with a
  `networkPolicy` key in spec.values  ->  postBuild variables substituted as Flux does
  (${ENV}, ${CLUSTER_NAME}, ${CONTAINER_REGISTRY}, ${APP_PACKAGE_VERSION_TO_BE_REPLACED})  ->
  helm pull of the pinned chart version from the HelmRepository's OCI url  ->  helm template
  ->  kubeconform -strict of the Cilium policies against the vendored CRD schema  ->
  netpol-broad-gate.py (the fluxcd gate against over-broad selectors).

An overlay whose environment is not in --allowed-envs may not carry the key at all: omega has
no netpol/ in fluxcd yet, so a block there would be a policy without a deny list. The error
names the files that hold the key.

Every failure is a `::error` annotation plus a block in $GITHUB_STEP_SUMMARY with the tool's
own output (the chart's `fail` text, the schema violation). Exit 1 on any failure.

Binaries: $KUSTOMIZE, $HELM, $KUBECONFORM (default: the names on PATH). `helm pull` needs a
registry login done by the caller. Charts are cached in --charts-dir as <chart>-<version>.tgz;
a file already there is used without a pull (a test can pre-seed it).

Skipped with one line each: an entry point not under overlays/, one whose kustomize build fails
(the kustomize step's verdict), a HelmRelease without spec.chart (chartRef), a chart other
than commons-app/postgres, a release whose values have no networkPolicy key.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

import yaml

CHARTS = {"commons-app", "postgres"}
CILIUM_KINDS = {"CiliumNetworkPolicy", "CiliumClusterwideNetworkPolicy"}
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
HERE = os.path.dirname(os.path.abspath(__file__))


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def env_of(entry_point):
    parts = os.path.normpath(entry_point).split(os.sep)
    return parts[parts.index("overlays") + 1] if "overlays" in parts and parts.index("overlays") + 1 < len(parts) else None


def substitute(text, env, ecr):
    for k, v in {
        "${ENV}": env,
        "${CLUSTER_NAME}": f"us-{env}-lw-kube-common",
        "${CONTAINER_REGISTRY}": ecr,
        "${APP_PACKAGE_VERSION_TO_BE_REPLACED}": "0.0.0",
    }.items():
        text = text.replace(k, v)
    return text


def files_with_key(kpath, env, others, release):
    """Files under <kpath> that name <release> and hold a networkPolicy key, other overlays left out."""
    skip = {os.path.join(kpath, "overlays", o) + os.sep for o in others if o != env}
    out = []
    for root, _, names in os.walk(kpath):
        for n in sorted(names):
            p = os.path.join(root, n)
            if any(p.startswith(s) for s in skip) or not n.endswith((".yaml", ".yml")):
                continue
            with open(p, errors="replace") as f:
                text = f.read()
            if re.search(r"^\s*networkPolicy:", text, re.M) and re.search(rf"^\s*name: {re.escape(release)}\s*$", text, re.M):
                out.append(p)
    return out


class Gate:
    def __init__(self, o):
        self.o = o
        self.errors = []  # (file, title, detail)
        self.checked = 0
        self.kustomize = os.environ.get("KUSTOMIZE", "kustomize")
        self.helm = os.environ.get("HELM", "helm")
        self.kubeconform = os.environ.get("KUBECONFORM", "kubeconform")
        os.makedirs(o.charts_dir, exist_ok=True)

    def error(self, file, title, detail=""):
        self.errors.append((file, title, detail))
        print(f"::error file={file}::{title}")
        if detail:
            print(detail.rstrip())

    def entry_point(self, ep):
        env = env_of(ep)
        if not env:
            print(f"skip {ep}: not under overlays/")
            return
        build = run([self.kustomize, "build", "--load-restrictor", "LoadRestrictionsNone", ep])
        if build.returncode:
            print(f"skip {ep}: kustomize build failed (the kustomize step reports it)")
            return
        docs = [d for d in yaml.safe_load_all(build.stdout) if isinstance(d, dict)]
        repos = {
            (d["metadata"].get("namespace"), d["metadata"]["name"]): d.get("spec") or {}
            for d in docs
            if d.get("kind") == "HelmRepository" and isinstance(d.get("metadata"), dict)
        }
        for d in docs:
            if d.get("kind") != "HelmRelease":
                continue
            md, spec = d.get("metadata") or {}, d.get("spec") or {}
            name, ns = md.get("name"), md.get("namespace")
            chart_spec = ((spec.get("chart") or {}).get("spec")) or {}
            chart = chart_spec.get("chart")
            if not chart:
                print(f"skip {ep}: HelmRelease {ns}/{name} has no spec.chart (chartRef): not rendered")
                continue
            if chart not in CHARTS:
                continue
            values = spec.get("values") or {}
            if "networkPolicy" not in values:
                continue
            files = files_with_key(self.o.kustomize_path, env, self.o.known_envs, name) or [ep]
            if env not in self.o.allowed_envs:
                self.error(
                    files[0],
                    f"networkPolicy in overlay {env}: {ns}/{name} ({chart}) — {env} has no netpol/ in fluxcd yet; "
                    f"the block may live only in overlays/{{{','.join(self.o.allowed_envs)}}}. Files: {', '.join(files)}",
                )
                continue
            self.release(ep, files[0], env, ns, name, chart, chart_spec, values, repos)

    def release(self, ep, file, env, ns, name, chart, chart_spec, values, repos):
        version = str(chart_spec.get("version") or "")
        if not SEMVER.match(version):
            self.error(file, f"{ns}/{name}: chart {chart} version '{version}' is not an exact pin; the gate renders exactly what Flux will")
            return
        ref = (chart_spec.get("sourceRef") or {})
        repo = repos.get((ref.get("namespace") or ns, ref.get("name")))
        url = substitute((repo or {}).get("url") or f"oci://{self.o.ecr_registry}/helm-charts", env, self.o.ecr_registry)
        if not url.startswith("oci://"):
            self.error(file, f"{ns}/{name}: HelmRepository url {url} is not oci://, cannot pull {chart}")
            return
        tgz = os.path.join(self.o.charts_dir, f"{chart}-{version}.tgz")
        if not os.path.exists(tgz):
            pull = run([self.helm, "pull", f"{url.rstrip('/')}/{chart}", "--version", version, "-d", self.o.charts_dir])
            if pull.returncode or not os.path.exists(tgz):
                self.error(file, f"{ns}/{name}: helm pull {url}/{chart} {version} failed (an ECR registry login is required)", pull.stdout + pull.stderr)
                return
        with tempfile.TemporaryDirectory() as tmp:
            vals = os.path.join(tmp, "values.yaml")
            with open(vals, "w") as f:
                f.write(substitute(yaml.safe_dump(values, sort_keys=False), env, self.o.ecr_registry))
            tpl = run([self.helm, "template", name, tgz, "-n", ns or "default", "-f", vals])
            if tpl.returncode:
                self.error(file, f"{ns}/{name}: helm template {chart} {version} with the {env} values failed", tpl.stdout + tpl.stderr)
                return
            policies = [d for d in yaml.safe_load_all(tpl.stdout) if isinstance(d, dict) and d.get("kind") in CILIUM_KINDS]
            rendered = os.path.join(tmp, "policies.yaml")
            with open(rendered, "w") as f:
                yaml.safe_dump_all(policies, f, sort_keys=False)
            verdict = f"{len(policies)} Cilium policies"
            if policies:
                kc = run([self.kubeconform, "-strict", "-summary", "-schema-location",
                          os.path.join(self.o.schemas, "{{.ResourceKind}}-{{.Group}}-{{.ResourceAPIVersion}}.json"), rendered])
                if kc.returncode:
                    self.error(file, f"{ns}/{name}: rendered policies fail the Cilium CRD schema", kc.stdout + kc.stderr)
                    return
                gate = run([sys.executable, "-I", os.path.join(HERE, "netpol-broad-gate.py"),
                            "--cluster", f"{env}/us-{env}-lw-kube-common",
                            "--node-subnets", os.path.join(HERE, "netpol-node-subnets.txt"),
                            "--allowlist", os.devnull, rendered])
                if gate.returncode:
                    self.error(file, f"{ns}/{name}: rendered policies are too broad (netpol-broad-gate)", gate.stdout + gate.stderr)
                    return
                verdict += ", kubeconform ok, broad gate ok"
            self.checked += 1
            print(f"ok   {ep}: {ns}/{name} {chart} {version}: {verdict}")

    def summary(self):
        path = os.environ.get("GITHUB_STEP_SUMMARY")
        if not path or not self.errors:
            return
        with open(path, "a") as f:
            f.write("### networkPolicy gate\n\n")
            for file, title, detail in self.errors:
                f.write(f"- `{file}`: {title}\n")
                if detail:
                    f.write(f"\n```\n{detail.strip()}\n```\n\n")


def main(argv=None):
    a = argparse.ArgumentParser()
    a.add_argument("--kustomize-path", default="kustomization")
    a.add_argument("--allowed-envs", default="omicron", help="comma-separated overlays that may carry the key")
    a.add_argument("--known-envs", default="omicron,omega", help="comma-separated overlay names, for naming the files of a rejected key")
    a.add_argument("--ecr-registry", default="515260921971.dkr.ecr.us-west-2.amazonaws.com")
    a.add_argument("--charts-dir", default=os.path.join(tempfile.gettempdir(), "netpol-gate-charts"))
    a.add_argument("--schemas", default=os.path.join(HERE, "schemas"))
    a.add_argument("entry_points", nargs="*")
    o = a.parse_args(argv)
    o.allowed_envs = [e for e in o.allowed_envs.split(",") if e]
    o.known_envs = [e for e in o.known_envs.split(",") if e]
    g = Gate(o)
    for ep in o.entry_points:
        g.entry_point(ep)
    g.summary()
    if g.errors:
        print(f"networkPolicy gate: {len(g.errors)} error(s)")
        return 1
    print(f"networkPolicy gate: {g.checked} release(s) rendered" if g.checked else f"no networkPolicy block in a {'/'.join(sorted(CHARTS))} HelmRelease under {o.kustomize_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
