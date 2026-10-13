"""Port of the GitLab check-encoding component (system/components/check-encoding).

Usage: check-encoding.py <extensions> [file ...]
  extensions  comma-separated, without dots (component default: txt,xml,json,config,cs,csproj,sln)
  files       the files to check; none = every tracked file (`git ls-files`).

Every file with one of the extensions must be UTF-8 (ASCII included). The component
detected the charset with Ude; a strict UTF-8 decode accepts the same files and rejects
windows-125x, UTF-16 and the like. Deleted or non-regular paths are skipped.
"""

import os
import subprocess
import sys

if len(sys.argv) < 2:
    sys.exit(__doc__)

extensions = {"." + e.strip().lower() for e in sys.argv[1].split(",") if e.strip()}
if len(sys.argv) > 2:
    paths = sys.argv[2:]
else:
    tracked = subprocess.run(["git", "ls-files", "-z"], check=True, capture_output=True).stdout
    paths = [os.fsdecode(p) for p in tracked.split(b"\0") if p]

checked = 0
wrong = []
for path in paths:
    if os.path.splitext(path)[1].lower() not in extensions or not os.path.isfile(path):
        continue
    checked += 1
    with open(path, "rb") as f:
        try:
            f.read().decode("utf-8")
        except UnicodeDecodeError as e:
            wrong.append(f"{path}: {e.reason} at byte {e.start}")

print(f"{checked} files checked ({', '.join(sorted(extensions))})")
if wrong:
    print("::error::The encoding of these files is not UTF-8:")
    print("\n".join(wrong))
    sys.exit(1)
