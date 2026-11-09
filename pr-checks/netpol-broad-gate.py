#!/usr/bin/env python3
# Vendored unchanged from maestra-io/fluxcd .github/scripts/netpol-broad-gate.py @ c2263864d6dac117f1126e8221e6e456259b2199 (2026-11-09); refresh = copy the file again and move this line.
"""Fail rendered network policies that open more than intended (issues-maestra#1685).

  V1 implicit-default-deny  Cilium policy with `endpointSelector: {}` and allow rules in a
                            direction whose `enableDefaultDeny.<dir>` is not false: every pod
                            of the namespace (CNP) or cluster (CCNP) flips to deny.
  V2 world-no-ports         `toEntities`/`fromEntities` with world/all and no ports/icmps.
  V3 cidr-zero-no-ports     /0 (`toCIDR`/`fromCIDR`, `*CIDRSet`, k8s `ipBlock`) without ports:
                            the same opening as world without ports. /0 with ports = world:<port>.
  V4 broad-cidr             prefix wider than /32 overlapping the cluster's node subnets
                            (Cilium matches node IPs as host identity), or wider than /24.

Host-firewall policies (`nodeSelector`) are skipped: they guard the nodes themselves, their
sources are the node VLANs by design, and default deny is their point. Deny rules
(`ingressDeny`/`egressDeny`) cannot open anything and are not checked.
Exceptions: lines `<cluster>/<Kind>/<ns|->/<name>:<V>  # until=YYYY-MM-DD reason=...` in the
allowlist file (absent file = no exceptions); a malformed or expired line is a failure.
"""
import argparse, datetime, ipaddress, re, sys
import yaml

WORLD = {"world", "world-ipv4", "world-ipv6", "all"}
CILIUM = {"CiliumNetworkPolicy", "CiliumClusterwideNetworkPolicy"}
KINDS = CILIUM | {"NetworkPolicy"}
WIDE_OUTSIDE = 24


class Loader(getattr(yaml, "CSafeLoader", yaml.SafeLoader)):  # rendered.yaml holds ~15k docs
    """SafeLoader plus the YAML 1.1 `=` value tag a bare `=` key resolves to (it is in renders)."""


Loader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))
ALLOW_LINE = re.compile(r"[^/\s]+/[^/\s]+/[^/\s]+/[^/\s]+/[^/\s]+:V[1-4]")


def docs(paths):
    for p in paths:
        with open(p) as f:
            for d in yaml.load_all(f, Loader=Loader):
                if not isinstance(d, dict):
                    continue
                if d.get("kind", "").endswith("List") and isinstance(d.get("items"), list):
                    yield from (i for i in d["items"] if isinstance(i, dict))
                else:
                    yield d


def specs(d):
    if d.get("kind") not in CILIUM:
        return [d.get("spec") or {}]
    out = [d["spec"]] if isinstance(d.get("spec"), dict) else []
    return out + [s for s in d.get("specs") or [] if isinstance(s, dict)]


def cidrs(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "except":
                continue
            if k in ("toCIDR", "fromCIDR") and isinstance(v, list):
                yield from (c for c in v if isinstance(c, str))
            elif k == "cidr" and isinstance(v, str):
                yield v
            else:
                yield from cidrs(v)
    elif isinstance(o, list):
        for x in o:
            yield from cidrs(x)


def check(d, subnets):
    kind, md = d.get("kind"), d.get("metadata") or {}
    out = []
    for s in specs(d):
        if "nodeSelector" in s:
            continue
        if kind in CILIUM and s.get("endpointSelector") == {}:
            edd = s.get("enableDefaultDeny") or {}
            for direction in ("ingress", "egress"):
                if s.get(direction) and edd.get(direction) is not False:
                    out.append(("V1", f"endpointSelector {{}} with {direction} rules, enableDefaultDeny.{direction} not false"))
        for direction in ("ingress", "egress"):
            for r in s.get(direction) or []:
                if not isinstance(r, dict):
                    continue
                ents = set(r.get("toEntities") or []) | set(r.get("fromEntities") or [])
                ported = bool(r.get("toPorts") or r.get("icmps") or r.get("ports"))
                if ents & WORLD and not ported:
                    out.append(("V2", f"{direction}: {sorted(ents & WORLD)} without ports"))
                for c in cidrs(r):
                    n = ipaddress.ip_network(c if "/" in c else c + ("/128" if ":" in c else "/32"), strict=False)
                    if n.prefixlen == 0:
                        if not ported:
                            out.append(("V3", f"{direction}: {c} without ports"))
                    elif n.prefixlen < n.max_prefixlen and any(n.version == sn.version and n.overlaps(sn) for sn in subnets):
                        out.append(("V4", f"{direction}: {c} overlaps a node subnet"))
                    elif n.prefixlen < WIDE_OUTSIDE:
                        out.append(("V4", f"{direction}: {c} wider than /{WIDE_OUTSIDE}"))
    key = f"{kind}/{md.get('namespace') or '-'}/{md.get('name')}"
    return [(key, v, msg) for v, msg in dict.fromkeys(out)]


def load_subnets(path, cluster):
    out = []
    for line in open(path):
        f = line.split("#", 1)[0].split()
        if len(f) == 2 and f[0] == cluster:
            out.append(ipaddress.ip_network(f[1]))
    return out


def load_allow(path, cluster, today):
    allow, errors = set(), []
    try:
        lines = open(path).read().splitlines()
    except FileNotFoundError:
        return allow, errors
    for n, line in enumerate(lines, 1):
        body, _, comment = line.partition("#")
        body = body.strip()
        if not body:
            continue
        m = re.search(r"until=(\d{4}-\d{2}-\d{2})", comment)
        if not m or "reason=" not in comment or not ALLOW_LINE.fullmatch(body):
            errors.append(f"{path}:{n}: want '<cluster>/<Kind>/<ns|->/<name>:V<n>  # until=YYYY-MM-DD reason=...'")
            continue
        if not body.startswith(cluster + "/"):
            continue
        if datetime.date.fromisoformat(m.group(1)) < today:
            errors.append(f"{path}:{n}: expired {m.group(1)}: {body}")
            continue
        allow.add(body[len(cluster) + 1:])
    return allow, errors


def main(argv=None, today=None):
    a = argparse.ArgumentParser()
    a.add_argument("--cluster", required=True)
    a.add_argument("--node-subnets", default=".github/scripts/netpol-node-subnets.txt")
    a.add_argument("--allowlist", default=".github/netpol-allowlist.txt")
    a.add_argument("manifests", nargs="+")
    o = a.parse_args(argv)
    subnets = load_subnets(o.node_subnets, o.cluster)
    if not subnets:
        print(f"::error::netpol gate: no node subnets for {o.cluster} in {o.node_subnets}")
        return 2
    allow, errors = load_allow(o.allowlist, o.cluster, today or datetime.date.today())
    seen, fails = 0, []
    for d in docs(o.manifests):
        if d.get("kind") not in KINDS:
            continue
        seen += 1
        for key, v, msg in check(d, subnets):
            if f"{key}:{v}" not in allow:
                fails.append(f"{o.cluster}/{key}:{v} — {msg}")
    for e in errors + fails:
        print(f"::error::netpol gate: {e}")
    print(f"netpol gate {o.cluster}: {seen} policies, {len(fails)} violations, {len(errors)} allowlist errors")
    return 1 if errors or fails else 0


if __name__ == "__main__":
    sys.exit(main())
