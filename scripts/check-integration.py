#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run the complete integration suite, or disjoint CI groups of the same tests."""
import argparse
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "Tests/Integration"


def flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from flatten(item)
        else:
            yield item


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--group", choices=("all", "main", "linux-agent"), default="all")
    parser.add_argument("--shard-index", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--list", action="store_true", help="List selected test IDs without running them.")
    args = parser.parse_args()
    if not 1 <= args.shard_count <= 64 or not 0 <= args.shard_index < args.shard_count:
        parser.error("Require 1..64 shards and 0 <= shard-index < shard-count.")

    sys.path.insert(0, str(TESTS))
    loader = unittest.TestLoader()
    cases = []
    for path in sorted(TESTS.glob("test_*.py")):
        linux_agent = path.name.startswith("test_linux_agent_")
        if args.group == "main" and linux_agent:
            continue
        if args.group == "linux-agent" and not linux_agent:
            continue
        cases.extend(flatten(loader.loadTestsFromName(path.stem)))
    if loader.errors:
        print("\n".join(loader.errors), file=sys.stderr)
        return 1

    cases.sort(key=lambda case: case.id())
    selected = cases[args.shard_index::args.shard_count]
    if not selected:
        parser.error("The selected test group/shard is empty.")
    if args.list:
        print("\n".join(case.id() for case in selected))
        return 0
    print(f"Integration group={args.group} shard={args.shard_index + 1}/{args.shard_count}: "
          f"{len(selected)} of {len(cases)} group tests", file=sys.stderr, flush=True)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(selected))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
