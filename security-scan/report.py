#!/usr/bin/env python3
"""Machine-readable reports of security-scan.yml for the SOC board (issues-maestra#1649).

Each scanner writes its native JSON; this keeps an ALLOWLIST of its fields and adds one hash
per finding, so the artifact never carries secret material:

  report.py gitleaks RAW OUT     gitleaks --redact JSON -> Secret / Match / Line / Author /
                                 Email / Message dropped; MatchSHA256 = sha256 of the
                                 REDACTED match (rule + file + this = identity across line shifts)
  report.py trivy RAW OUT        trivy JSON -> vulnerabilities as they are (no code), secrets
                                 without Match / Code (MatchSHA256 of trivy's masked match)
  report.py opengrep RAW OUT     opengrep --json-output -> results without extra.lines
                                 (SnippetSHA256 = sha256 of the whitespace-collapsed lines)
  report.py check DIR [RAW...]   fails when a report holds a dropped key, or when any secret of
                                 the UNREDACTED gitleaks reports RAW (never printed, never
                                 uploaded) occurs in any file of DIR
  report.py --self-test

Hashes are the first 16 hex of sha256: an identity, not a way back to the value.
"""
import hashlib
import json
import os
import sys

FORBIDDEN = {"Secret", "Match", "Line", "Author", "Email", "Message", "Code", "lines"}
MIN_SECRET = 6  # a shorter raw value occurs in ordinary text by chance


def h(text):
    return hashlib.sha256((text or "").encode()).hexdigest()[:16]


def pick(d, keys):
    return {k: d[k] for k in keys if k in d}


def gitleaks(raw):
    keys = ("RuleID", "Description", "File", "SymlinkFile", "StartLine", "EndLine", "StartColumn",
            "EndColumn", "Commit", "Date", "Tags", "Entropy", "Fingerprint")
    return [{**pick(f, keys), "MatchSHA256": h(f.get("Match"))} for f in raw or []]


def trivy(raw):
    vkeys = ("VulnerabilityID", "PkgID", "PkgName", "PkgPath", "InstalledVersion", "FixedVersion",
             "Status", "Severity", "PrimaryURL", "CweIDs")
    skeys = ("RuleID", "Category", "Severity", "Title", "StartLine", "EndLine")
    results = []
    for r in raw.get("Results") or []:
        out = pick(r, ("Target", "Class", "Type"))
        if r.get("Vulnerabilities"):
            out["Vulnerabilities"] = [{**pick(v, vkeys), "Title": (v.get("Title") or "")[:300]}
                                      for v in r["Vulnerabilities"]]
        if r.get("Secrets"):
            out["Secrets"] = [{**pick(s, skeys), "MatchSHA256": h(s.get("Match"))} for s in r["Secrets"]]
        results.append(out)
    return {**pick(raw, ("SchemaVersion", "CreatedAt", "ArtifactName", "ArtifactType")), "Results": results}


def opengrep(raw):
    mkeys = ("category", "subcategory", "cwe", "owasp", "confidence", "likelihood", "impact",
             "vulnerability_class", "technology", "source", "shortlink")
    results = []
    for r in raw.get("results") or []:
        e = r.get("extra") or {}
        results.append({
            **pick(r, ("check_id", "path", "start", "end")),
            "extra": {
                "severity": e.get("severity"),
                "message": (e.get("message") or "")[:1000],
                "metadata": pick(e.get("metadata") or {}, mkeys),
                "SnippetSHA256": h(" ".join((e.get("lines") or "").split())),
            },
        })
    return {"version": raw.get("version"), "results": results, "errors": len(raw.get("errors") or [])}


def walk_keys(v):
    if isinstance(v, dict):
        for k, x in v.items():
            yield k
            yield from walk_keys(x)
    elif isinstance(v, list):
        for x in v:
            yield from walk_keys(x)


def check(out_dir, raws):
    """Problems (never the value itself): forbidden keys, raw secrets found in the output."""
    secrets = set()
    for p in raws:
        if os.path.exists(p):
            with open(p) as fh:
                secrets |= {f.get("Secret") or "" for f in json.load(fh) or []}
    secrets = {s for s in secrets if len(s) >= MIN_SECRET}
    problems = []
    for name in sorted(os.listdir(out_dir)):
        path = os.path.join(out_dir, name)
        with open(path) as fh:
            text = fh.read()
        if name.endswith(".json"):
            bad = sorted(set(walk_keys(json.loads(text))) & FORBIDDEN)
            if bad:
                problems.append(f"{name}: dropped keys present: {', '.join(bad)}")
        # the value as written, and as JSON escapes it
        hits = sum(1 for s in secrets if s in text or json.dumps(s)[1:-1] in text)
        if hits:
            problems.append(f"{name}: {hits} raw secret value(s) present")
    return problems


def main(argv):
    if argv[0] == "check":
        problems = check(argv[1], argv[2:])
        for p in problems:
            print(f"::error::{p}")
        return 1 if problems else 0
    tool, raw_path, out_path = argv
    with open(raw_path) as fh:
        raw = json.load(fh)
    with open(out_path, "w") as fh:
        json.dump({"gitleaks": gitleaks, "trivy": trivy, "opengrep": opengrep}[tool](raw), fh)
    return 0


def self_test():
    import tempfile
    secret = "selftest-" + "value-0042"  # built, so no scanner reads it as a key
    gl = [{"RuleID": "aws-access-token", "File": "a.py", "StartLine": 3, "Secret": "REDACTED",
           "Match": "key = REDACTED", "Line": "key = REDACTED", "Author": "x", "Email": "x@y", "Fingerprint": "a.py:aws-access-token:3"}]
    out = gitleaks(gl)
    assert set(out[0]) & FORBIDDEN == set(), out
    assert out[0]["MatchSHA256"] == h("key = REDACTED") and len(out[0]["MatchSHA256"]) == 16
    tv = {"SchemaVersion": 2, "Results": [{"Target": "x.csproj", "Type": "nuget", "Vulnerabilities": [
        {"VulnerabilityID": "CVE-1", "PkgName": "P", "InstalledVersion": "1", "FixedVersion": "2", "Severity": "HIGH",
         "Description": "long", "Title": "t" * 400}]}, {"Target": "k", "Class": "secret", "Secrets": [
        {"RuleID": "r", "Severity": "HIGH", "StartLine": 1, "Match": "k=****", "Code": {"Lines": [{"Content": "k=****"}]}}]}]}
    t = trivy(tv)
    assert len(t["Results"][0]["Vulnerabilities"][0]["Title"]) == 300
    assert "Description" not in t["Results"][0]["Vulnerabilities"][0]
    assert set(walk_keys(t)) & FORBIDDEN == set()
    og = {"version": "1.33.1", "errors": [{}], "results": [{"check_id": "r.x", "path": "a.sh", "start": {"line": 2},
          "end": {"line": 2}, "extra": {"severity": "ERROR", "message": "m", "lines": "  run:  echo ${{ x }}\n",
                                        "metadata": {"cwe": ["CWE-78"], "references": ["u"]}}}]}
    o = opengrep(og)
    assert o["errors"] == 1 and "lines" not in o["results"][0]["extra"]
    assert o["results"][0]["extra"]["SnippetSHA256"] == h("run: echo ${{ x }}")
    with tempfile.TemporaryDirectory() as d:
        raw, out_dir = os.path.join(d, "raw.json"), os.path.join(d, "out")
        os.mkdir(out_dir)
        with open(raw, "w") as fh:
            json.dump([{"Secret": secret}, {"Secret": "short"}], fh)
        with open(os.path.join(out_dir, "gitleaks-dir.json"), "w") as fh:
            json.dump(out, fh)
        assert check(out_dir, [raw]) == [], check(out_dir, [raw])
        # a raw value anywhere, or a dropped key, fails the check
        with open(os.path.join(out_dir, "leak.json"), "w") as fh:
            json.dump([{"File": "a", "Note": f"x {secret} y"}], fh)
        assert check(out_dir, [raw]) == ["leak.json: 1 raw secret value(s) present"], check(out_dir, [raw])
        with open(os.path.join(out_dir, "leak.json"), "w") as fh:
            json.dump([{"File": "a", "Match": "m"}], fh)
        assert check(out_dir, [raw]) == ["leak.json: dropped keys present: Match"], check(out_dir, [raw])
    print("self-test ok")
    return 0


if __name__ == "__main__":
    sys.exit(self_test() if sys.argv[1:] == ["--self-test"] else main(sys.argv[1:]))
