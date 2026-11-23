#!/usr/bin/env python3
"""rules-bundle.py <rules dir> <out dir>: an opengrep config dir with one rule file per directory.

opengrep validates each config file in its own semgrep-core call: the ~1450 files of the
semgrep-rules security selection take ~3.5 min to load on pool=small, their ~310 directories
about a third of that. The directories are kept: <out dir>/<dir>/rules.yaml holds the rules of
<rules dir>/<dir>/*.yaml in file name order. Of the rules that share an id (tainted-sql-string:
13 directories) opengrep runs one, picked by the order it reads the files in, as with the dir.
The text is not re-serialised (a YAML round trip can change scalars): the `rules:` sequence of
each file is re-indented to one column and appended. The one difference: a block scalar that
ends a file without a final newline gets one (3 patterns in semgrep-rules; a pattern's trailing
newline does not change what it matches). Source files as opengrep reads a config dir: *.yaml,
minus *.test.yaml (rule test fixtures).
  rules-bundle.py --self-test
"""
import os, re, sys

COL = 4  # the deepest item column in semgrep-rules


def items(path, text):
    """The lines of the `rules:` sequence of one rule file, its items moved to column COL."""
    lines = text.split("\n")[:-1] if text.endswith("\n") else text.split("\n")  # no blank line added after a |+ scalar
    head = [i for i, l in enumerate(lines) if l and not l[0].isspace() and not l.startswith(("#", "-"))]
    if [lines[i].rstrip() for i in head] != ["rules:"]:
        sys.exit(f"rules-bundle: {path}: not a single top-level `rules:` key")
    body = lines[head[0] + 1:]
    first = next((m for l in body for m in [re.match(r"( *)-( |$)", l)] if l.strip() and not l.lstrip().startswith("#")), None)
    if not first or len(first.group(1)) > COL:
        sys.exit(f"rules-bundle: {path}: no rule list at column 0..{COL}")
    pad = " " * (COL - len(first.group(1)))
    return [pad + l if l else l for l in body]


def bundle(root):
    """{output file path relative to the out dir: text}"""
    out = {}
    for d, dirs, files in os.walk(root):
        dirs.sort()
        lines = []
        for f in sorted(files):
            if f.endswith(".yaml") and not f.endswith(".test.yaml"):
                p = os.path.join(d, f)
                with open(p, encoding="utf-8") as fh:
                    lines += items(p, fh.read())
        if lines:
            out[os.path.join(os.path.relpath(d, root), "rules.yaml")] = "\n".join(["rules:"] + lines) + "\n"
    return out


def self_test():
    import tempfile
    d = tempfile.mkdtemp()
    for name, text in (("a/x.yaml", "# c\nrules:\n- id: a\n  pattern: |\n    f(\n      $X)\n"),
                       ("a/y.yaml", "rules:\n  - id: b\n\n    pattern: g()\n"),
                       ("a/b/z.yaml", "rules:\n -\n    id: a\n"),
                       ("a/b/z.test.yaml", "rules:\n- id: fixture\n")):
        os.makedirs(os.path.dirname(os.path.join(d, name)), exist_ok=True)
        with open(os.path.join(d, name), "w") as f:
            f.write(text)
    got = bundle(d)
    assert got == {"a/rules.yaml": "rules:\n    - id: a\n      pattern: |\n        f(\n          $X)\n"
                                   "    - id: b\n\n      pattern: g()\n",
                   "a/b/rules.yaml": "rules:\n    -\n       id: a\n"}, got
    print("rules-bundle self-test ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 3:
        for name, text in bundle(sys.argv[1]).items():
            os.makedirs(os.path.dirname(os.path.join(sys.argv[2], name)))
            with open(os.path.join(sys.argv[2], name), "w", encoding="utf-8") as f:
                f.write(text)
    else:
        sys.exit(__doc__)
