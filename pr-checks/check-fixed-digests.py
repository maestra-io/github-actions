#!/usr/bin/env python3
"""Fail a PR that runs a fixed-digest image under a tag the clusters cannot pin.

  check-fixed-digests.py <fixed-digests.yaml> <built overlays.yaml>...

The clusters pin some images by digest at Pod admission instead of in git:
clickhouse/clickhouse-server, because the Altinity operator reads the server version
from the CHI's image tag and a `tag@sha256` breaks new replicas (issues-maestra#1726,
Altinity/clickhouse-operator#2149). Kyverno adds the digest from fluxcd's
`fixedDigests` map (vendored here as fixed-digests.yaml). Where a cluster enforces it,
a bare tag that is not in the map is DENIED: the ClickHouse Pod never starts. This
fails the PR instead, for every image of a mapped repository in the built overlays:
  - a string `image:` or a `{repository, tag}` pair (HelmRelease values, CRs);
  - a `{repository}` with no tag: the chart's default would decide the version.
An image that already carries @sha256 is left alone (not a CHI, e.g. a client Job).
Fix: add `<tag>: <multi-arch index digest>` to fixedDigests in maestra-io/fluxcd
base/kyverno-nora-pull-through/chart/values.yaml, merge, then refresh
fixed-digests.yaml here (its header says how).
"""
import re
import sys

import yaml

# ponytail: Docker Hub and nora names only; the map holds docker-hub keys today.
REGISTRIES = {"docker.io": "docker-hub", "index.docker.io": "docker-hub"}
NORA = "packages.maestra.io"


def nora_key(image):
    """`<prefix>/<repo>[:<tag>]` as fluxcd's map spells it, or None for another registry."""
    name = image.partition("@")[0]
    first, _, rest = name.partition("/")
    if rest and ("." in first or ":" in first or first == "localhost"):
        host, path = first, rest
    else:
        host, path = "docker.io", name
    if host == NORA:
        return path
    prefix = REGISTRIES.get(host)
    if not prefix:
        return None
    if "/" not in path.split(":")[0]:
        path = f"library/{path}"
    return f"{prefix}/{path}"


def refs(obj, out):
    """(image, has_tag) for every string `image:` and every `{repository[, tag]}` mapping."""
    if isinstance(obj, dict):
        repo, tag = obj.get("repository"), obj.get("tag")
        if isinstance(repo, str):
            tag = str(tag) if tag not in (None, "") else ""
            out.append((f"{repo}:{tag}" if tag else repo, bool(tag)))
        for k, v in obj.items():
            if k == "image" and isinstance(v, str):
                out.append((v, True))
            else:
                refs(v, out)
    elif isinstance(obj, list):
        for v in obj:
            refs(v, out)
    return out


def check(fixed, docs):
    repos = {k.rpartition(":")[0] for k in fixed}
    errs = set()
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        meta = doc.get("metadata") or {}
        where = f"{doc.get('kind', '?')}/{meta.get('namespace', '-')}/{meta.get('name', '?')}"
        found = refs(doc, [])
        spec = doc.get("spec") or {}
        if doc.get("kind") == "HelmRelease" and ((spec.get("chart") or {}).get("spec") or {}).get("chart") == "clickhouse":
            # helm-charts-clickhouse: the server image is clickhouse.image, repository
            # defaulted by the chart, tag by its appVersion when unset.
            img = ((spec.get("values") or {}).get("clickhouse") or {}).get("image") or {}
            tag = img.get("tag")
            repo = img.get("repository") or "clickhouse/clickhouse-server"
            found.append((f"{repo}:{tag}" if tag not in (None, "") else repo, tag not in (None, "")))
        for image, has_tag in found:
            if "$" in image or "{{" in image or "@" in image:
                continue
            key = nora_key(image)
            if not key:
                continue
            repo = key if not has_tag else key.rpartition(":")[0]
            if repo not in repos:
                continue
            if not has_tag:
                errs.add(f"{where}: {image} has no tag, so the chart default picks the version; "
                         f"set the tag explicitly to one listed in fixedDigests")
            elif key not in fixed:
                errs.add(f"{where}: {image} is not in fixedDigests, so the clusters cannot pin it "
                         f"and deny its Pods. Add `\"{key}\": <index digest>` to fixedDigests in "
                         f"maestra-io/fluxcd base/kyverno-nora-pull-through/chart/values.yaml first "
                         f"(issues-maestra#1726)")
    return sorted(errs)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    with open(argv[0]) as f:
        fixed = (yaml.safe_load(f) or {}).get("fixedDigests") or {}
    docs = []
    for path in argv[1:]:
        with open(path) as f:
            docs += list(yaml.safe_load_all(f))
    errs = check(fixed, docs)
    for e in errs:
        print(f"::error title=image tag not in fixedDigests::{e}")
    print(f"fixed-digest check: {len(fixed)} pinned tag(s), {len(errs)} problem(s)")
    return 1 if errs else 0


def self_test():
    fixed = {"docker-hub/clickhouse/clickhouse-server:26.8.2.7": "sha256:" + "1" * 64}

    def hr(image):
        return {"kind": "HelmRelease", "metadata": {"namespace": "ns", "name": "ch"},
                "spec": {"values": {"clickhouse": {"image": image}}}}
    ok = [hr({"repository": "clickhouse/clickhouse-server", "tag": "26.8.2.7"}),
          hr({"repository": "packages.maestra.io/docker-hub/clickhouse/clickhouse-server", "tag": "26.8.2.7"}),
          hr({"repository": "clickhouse/clickhouse-server", "tag": "25.8.28.1@sha256:" + "2" * 64}),
          hr({"repository": "clickhouse/clickhouse-keeper", "tag": "26.1"}),
          hr({"repository": "cr.yandex/x/docker.io/clickhouse/clickhouse-server", "tag": "25.3"}),
          hr({"repository": "clickhouse/clickhouse-server", "tag": "${TAG}"}),
          {"kind": "Job", "spec": {"containers": [{"image": "docker.io/clickhouse/clickhouse-server:26.8.2.7"}]}}]
    assert check(fixed, ok) == [], check(fixed, ok)
    bad = {"string": {"kind": "Job", "spec": {"containers": [{"image": "clickhouse/clickhouse-server:26.9.1.1"}]}},
           "pair": hr({"repository": "clickhouse/clickhouse-server", "tag": "26.9.1.1"}),
           "no tag": hr({"repository": "clickhouse/clickhouse-server"}),
           "float tag": hr({"repository": "clickhouse/clickhouse-server", "tag": 26.8})}

    def chart(values):
        return {"kind": "HelmRelease", "metadata": {"namespace": "ns", "name": "ch"},
                "spec": {"chart": {"spec": {"chart": "clickhouse"}}, "values": values}}
    assert check(fixed, [chart({"clickhouse": {"image": {"tag": "26.8.2.7"}}})]) == []
    bad["chart tag only"] = chart({"clickhouse": {"image": {"tag": "26.9.1.1"}}})
    bad["chart no image"] = chart({"clickhouse": {"replicas": 2}})
    for name, doc in bad.items():
        assert len(check(fixed, [doc])) == 1, name
    assert "no tag" in check(fixed, [bad["no tag"]])[0]
    assert nora_key("nginx:1") == "docker-hub/library/nginx:1"
    assert nora_key("ghcr.io/a/b:1") is None
    print("self-test ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        sys.exit(0)
    sys.exit(main(sys.argv[1:]))
