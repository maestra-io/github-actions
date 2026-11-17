#!/usr/bin/env python3
"""pr-diff.py: the trivy half of pr-scan.sh (pull_request mode of security-scan.yml).

  pr-diff.py any <head.json>               exit 0 when the trivy JSON has a finding, else 1
  pr-diff.py trivy <base.json> <head.json> [<base root> <head root>]
                                           print the head findings absent from the base; exit 1
                                           when there is one, else 0
  pr-diff.py --self-test
  Exit 2 on an unreadable report (a crash never reads as 0 or 1).

Key of a finding, never a line number: vulnerability = (target, package, advisory id), so a
PR that leaves a vulnerable package alone (or bumps it within the same advisory) adds nothing;
secret = (target, rule id, sha256 of the matched lines read from the scanned tree under its root,
whitespace-normalised), so a secret moved within its file stays the old finding and a token
replaced by another of the same length is new (trivy's redacted Match cannot tell them apart; it
is the fallback when the file cannot be read). Secret values are never printed or stored: only
the hash, the rule, the file and the line number.
"""
import hashlib, json, os, sys


def raw_lines(root, target, start, end):
    """sha256 of lines start..end of root/target, whitespace-normalised; None if unreadable."""
    if not root or not start:
        return None
    try:
        with open(os.path.join(root, target), "rb") as f:
            lines = f.read().split(b"\n")[start - 1:(end or start)]
    except OSError:
        return None
    return hashlib.sha256(b" ".join(b" ".join(l.split()) for l in lines)).hexdigest()


def findings(path, root=None):
    with open(path) as f:
        doc = json.load(f)
    for r in doc.get("Results") or []:
        t = r.get("Target", "")
        for v in r.get("Vulnerabilities") or []:
            key = ("vuln", t, v.get("PkgName", ""), v.get("VulnerabilityID", ""))
            yield key, f"{v.get('Severity')} {v.get('VulnerabilityID')} {v.get('PkgName')} {v.get('InstalledVersion')} in {t}"
        for s in r.get("Secrets") or []:
            ident = raw_lines(root, t, s.get("StartLine"), s.get("EndLine")) or " ".join(str(s.get("Match", "")).split())
            key = ("secret", t, s.get("RuleID", ""), ident)
            yield key, f"{s.get('Severity')} secret {s.get('RuleID')} in {t}:{s.get('StartLine')}"


def new_findings(base, head):
    old = {k for k, _ in base}
    return [(k, text) for k, text in head if k not in old]


def main(argv):
    if argv[:1] == ["any"]:
        return 0 if any(True for _ in findings(argv[1])) else 1
    if argv[:1] == ["trivy"]:
        roots = argv[3:5] if len(argv) >= 5 else [None, None]
        head = list(findings(argv[2], roots[1]))
        new = new_findings(findings(argv[1], roots[0]), head)
        print(f"trivy: {len(head)} HIGH/CRITICAL findings at head, {len(head) - len(new)} already on the base, {len(new)} introduced by this PR")
        for _, text in sorted(set(new)):
            print(f"  NEW {text}")
        return 1 if new else 0
    if argv[:1] == ["--self-test"]:
        return self_test()
    print(__doc__, file=sys.stderr)
    return 2


def self_test():
    import os, tempfile
    def doc(vulns=(), secrets=()):
        return {"Results": [{"Target": "requirements.txt", "Vulnerabilities": [
            {"PkgName": p, "InstalledVersion": ver, "VulnerabilityID": cve, "Severity": "HIGH"} for p, ver, cve in vulns]},
            {"Target": "app/config.py", "Secrets": [
                {"RuleID": r, "Match": m, "StartLine": ln, "Severity": "CRITICAL"} for r, m, ln in secrets]}]}
    d = tempfile.mkdtemp()
    def put(name, o):
        p = os.path.join(d, name)
        with open(p, "w") as f:
            json.dump(o, f)
        return p
    base = put("base.json", doc([("pyyaml", "5.3", "CVE-2020-14343")], [("aws-access-key-id", "key = ****", 3)]))
    # unchanged findings, the secret moved down the file, the package bumped within the advisory
    same = put("same.json", doc([("pyyaml", "5.3.1", "CVE-2020-14343")], [("aws-access-key-id", "key  =  ****", 40)]))
    newcve = put("newcve.json", doc([("pyyaml", "5.3", "CVE-2020-14343"), ("django", "3.2.0", "CVE-2021-35042")]))
    newsecret = put("newsecret.json", doc([], [("aws-access-key-id", "key = ****", 3), ("github-pat", "token = ****", 9)]))
    empty = put("empty.json", {"Results": [{"Target": "go.sum"}]})
    assert main(["trivy", base, same]) == 0
    assert main(["trivy", base, newcve]) == 1
    assert main(["trivy", base, newsecret]) == 1
    assert main(["trivy", empty, newcve]) == 1
    assert main(["any", empty]) == 1 and main(["any", base]) == 0
    import subprocess
    bad = put("bad.json", None)
    with open(bad, "w") as f:
        f.write("{truncated")
    for args in (["any", bad], ["any", os.path.join(d, "missing.json")], ["trivy", base, bad]):
        assert subprocess.run([sys.executable, __file__, *args], capture_output=True).returncode == 2, args
    # raw-line identity: same redacted Match, different token -> new; same token moved -> old
    for side, tok, ln in (("b", "AAAA", 2), ("h1", "AAAA", 5), ("h2", "BBBB", 2)):
        os.makedirs(os.path.join(d, side, "app"), exist_ok=True)
        with open(os.path.join(d, side, "app", "config.py"), "w") as f:
            f.write("\n" * (ln - 1) + f"key = {tok}\n")
    sb = put("sb.json", doc([], [("aws-access-key-id", "key = ****", 2)]))
    sh1 = put("sh1.json", doc([], [("aws-access-key-id", "key = ****", 5)]))
    sh2 = put("sh2.json", doc([], [("aws-access-key-id", "key = ****", 2)]))
    for doc_ in (sb, sh1, sh2):  # EndLine as trivy writes it
        o = json.load(open(doc_)); o["Results"][1]["Secrets"][0]["EndLine"] = o["Results"][1]["Secrets"][0]["StartLine"]; json.dump(o, open(doc_, "w"))
    assert main(["trivy", sb, sh1, os.path.join(d, "b"), os.path.join(d, "h1")]) == 0
    assert main(["trivy", sb, sh2, os.path.join(d, "b"), os.path.join(d, "h2")]) == 1
    print("pr-diff self-test ok")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:  # a crash is exit 2 (broken), never 1 (= no findings / new findings)
        print(f"pr-diff: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)
