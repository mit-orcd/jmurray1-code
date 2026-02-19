#!/usr/bin/env python3
import subprocess
import sys
import shutil
from typing import List, Tuple, Set

# ---- CONFIG ----
PARTITIONS = [
    "sched_mit_hill",
    "newnodes",
    # add more if needed...
]

START = "now-90days"   # or "2026-02-01", etc.
END = "now"
# ----------------

def run(cmd: List[str]) -> str:
    out = subprocess.run(cmd, check=True, stdout=subprocess.PIPE, text=True)
    return out.stdout.strip()

def sacct_user_partition(start: str, end: str) -> List[Tuple[str, str]]:
    cmd = [
        "sacct", "-a", "-n", "-p",
        "-S", start, "-E", end,
        "-o", "User,Partition"
    ]
    out = run(cmd)
    rows = []
    for line in out.splitlines():
        if not line.strip():
            continue
        fields = line.split("|")
        if len(fields) >= 2:
            user, part = fields[0].strip(), fields[1].strip()
            if user and part:
                rows.append((user, part))
    return rows

def main():
    # verify sacct exists
    if shutil.which("sacct") is None:
        sys.stderr.write("Error: sacct not found on PATH.\n")
        sys.exit(1)

    rows = sacct_user_partition(START, END)

    users: Set[str] = set()
    for user, part in rows:
        if part in PARTITIONS:
            users.add(user)

    print("# Users who have used C7 public non-OOD partitions")
    print("# Time window:", START, "to", END)
    print("# Partitions:", ", ".join(PARTITIONS))
    print()
    for u in sorted(users):
        print(u)

if __name__ == "__main__":
    main()
