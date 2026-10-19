#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Lease tests inspect process-wide descriptor custody and must not share a
# process with unrelated spawning suites. Both commands are required.
./scripts/swift.sh test --jobs "${MACOPENVM_TEST_JOBS:-2}" --skip LeaseSpawnTests
./scripts/swift.sh test --skip-build --jobs "${MACOPENVM_TEST_JOBS:-2}" --filter LeaseSpawnTests
xcrun swift-format lint --strict --recursive App Core Backends Storage RuntimeIPC GuestAgent CLI Tests Benchmarks/ProcessMonitor Package.swift
python3 GuestAgent/Protocol/generate.py --check
python3 scripts/sbom.py --check
python3 -m unittest discover -s Benchmarks -p 'test_*.py'
python3 scripts/check-integration.py --group "${MACOPENVM_INTEGRATION_GROUP:-all}"
shopt -s nullglob
results=(Benchmarks/results/*.json)
if test "${#results[@]}" -gt 0; then python3 Benchmarks/validate_result.py "${results[@]}"; fi
