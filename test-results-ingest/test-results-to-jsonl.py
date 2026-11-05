#!/usr/bin/env python3
"""TRX / JUnit XML -> one JSON line per test result, for VictoriaLogs /insert/jsonline.

usage: test-results-to-jsonl.py [files or dirs...] > rows.jsonl
Context (repo, workflow, job, run_id, run_attempt, sha, branch, event, pr) comes
from the GitHub Actions env (GITHUB_*); missing values are left empty.
"""
import hashlib, json, os, sys, glob
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

TRX_NS = "{http://microsoft.com/schemas/VisualStudio/TeamTest/2010}"


def ctx():
    ref = os.environ.get("GITHUB_REF_NAME", "")
    head_ref = os.environ.get("GITHUB_HEAD_REF", "")  # PR source branch
    pr = ref.split("/")[0] if ref.endswith("/merge") else ""
    return {
        "repo": os.environ.get("GITHUB_REPOSITORY", ""),
        "workflow": os.environ.get("GITHUB_WORKFLOW", ""),
        "job": os.environ.get("GITHUB_JOB", "") + os.environ.get("TEST_RESULTS_JOB_SUFFIX", ""),
        "run_id": os.environ.get("GITHUB_RUN_ID", ""),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""),
        "sha": os.environ.get("GITHUB_SHA", ""),
        "branch": head_ref or ref,
        "event": os.environ.get("GITHUB_EVENT_NAME", ""),
        "pr": pr,
    }


def fhash(message, stack):
    """Stable id of a failure: first line of the message + first stack frame."""
    key = (message or "").strip().splitlines()[:1] + (stack or "").strip().splitlines()[:1]
    return hashlib.sha256("\n".join(key).encode()).hexdigest()[:16] if key else ""


def trx_duration_ms(s):
    # hh:mm:ss.fffffff
    try:
        h, m, sec = s.split(":")
        return int(round((int(h) * 3600 + int(m) * 60 + float(sec)) * 1000))
    except Exception:
        return None


def parse_trx(path):
    root = ET.parse(path).getroot()
    defs = {}
    for ut in root.iter(TRX_NS + "UnitTest"):
        tm = ut.find(TRX_NS + "TestMethod")
        if tm is not None:
            defs[ut.get("id")] = (tm.get("className", ""), tm.get("name", ""))
    for r in root.iter(TRX_NS + "UnitTestResult"):
        cls, name = defs.get(r.get("testId"), ("", r.get("testName", "")))
        name = r.get("testName") or name
        # MSTest's testName is the method plus DataRow arguments ("Rows (1)") and className the
        # class FQN; xunit's testName is already fully qualified, so prepend only when it is not.
        test_id = f"{cls}.{name}" if cls and not name.startswith(cls + ".") else name
        outcome = (r.get("outcome") or "").lower()
        outcome = {"notexecuted": "skipped", "inconclusive": "skipped", "passed": "passed", "failed": "failed"}.get(outcome, outcome or "unknown")
        err = r.find(f"{TRX_NS}Output/{TRX_NS}ErrorInfo")
        msg = err.findtext(TRX_NS + "Message", "") if err is not None else ""
        stack = err.findtext(TRX_NS + "StackTrace", "") if err is not None else ""
        yield {
            "test_id": test_id,
            "outcome": outcome,
            "duration_ms": trx_duration_ms(r.get("duration", "")),
            "failure_hash": fhash(msg, stack) if outcome == "failed" else "",
            "message": (msg or "")[:500],
            "_time": r.get("endTime") or r.get("startTime") or "",
        }


def parse_junit(path):
    root = ET.parse(path).getroot()
    suites = [root] if root.tag == "testsuite" else root.iter("testsuite")
    for suite in suites:
      for tc in suite.iter("testcase"):
          cls, name = tc.get("classname", ""), tc.get("name", "")
          test_id = f"{cls}.{name}" if cls else name
          outcome, msg, stack = "passed", "", ""
          for tag, o in (("failure", "failed"), ("error", "failed"), ("skipped", "skipped")):
              e = tc.find(tag)
              if e is not None:
                  outcome, msg, stack = o, e.get("message", "") or "", (e.text or "")
                  break
          try:
              dur = int(round(float(tc.get("time", "0")) * 1000))
          except ValueError:
              dur = None
          yield {
              "test_id": test_id,
              "outcome": outcome,
              "duration_ms": dur,
              "failure_hash": fhash(msg, stack) if outcome == "failed" else "",
              "message": msg[:500],
              "_time": tc.get("timestamp") or suite.get("timestamp") or "",
          }


def files(args):
    for a in args:
        if os.path.isdir(a):
            for pat in ("**/*.trx", "**/*.xml"):
                yield from glob.glob(os.path.join(a, pat), recursive=True)
        else:
            yield a


def main():
    base, now = ctx(), datetime.now(timezone.utc).isoformat()
    n = 0
    for f in files(sys.argv[1:] or ["."]):
        try:
            head = open(f, "rb").read(2048)
        except OSError:
            continue
        if b"TestRun" in head and b"TeamTest" in head:
            rows = parse_trx(f)
        elif b"<testsuite" in head:
            rows = parse_junit(f)
        else:
            continue
        for r in rows:
            r["_time"] = r["_time"] or now
            r["file"] = os.path.basename(f)
            print(json.dumps({**base, **r}, ensure_ascii=False))
            n += 1
    print(f"test-results-to-jsonl: {n} rows", file=sys.stderr)


if __name__ == "__main__":
    main()
