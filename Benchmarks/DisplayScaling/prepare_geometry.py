#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Stage exact original/current geometry sources in a CPU-only isolated Swift package."""
import argparse
import hashlib
import json
from pathlib import Path

PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DisplayGeometryFixture", platforms: [.macOS(.v14)], products: [
  .executable(name: "GeometryHotpath", targets: ["GeometryHotpath"])
], targets: [
  .target(name: "BackendAPI"),
  .target(name: "BaselineGeometry", dependencies: ["BackendAPI"]),
  .target(name: "CandidateGeometry", dependencies: ["BackendAPI"]),
  .executableTarget(name: "GeometryHotpath", dependencies: ["BackendAPI", "BaselineGeometry", "CandidateGeometry"])
])
'''
API = '''// SPDX-License-Identifier: Apache-2.0
// Minimal fixture types only; successful geometry arithmetic is unmodified.
public struct PixelSize: Equatable, Sendable {
  public let width: Int
  public let height: Int
  public init(width: Int, height: Int) { self.width = width; self.height = height }
}
public struct VMError: Error, Sendable {
  public enum Code: Sendable { case invalidConfiguration }
  public init(_ code: Code, _ message: String, recovery: String) {}
}
'''


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def portable(raw):
    # Foundation supplies CGRect on non-Apple Swift hosts. This only guards the
    # import; every production declaration and function body remains exact.
    return raw.replace(b"import CoreGraphics\n", b"#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\n")


def prepare(original, candidate, output):
    output.mkdir(mode=0o700)
    bodies = {"Package.swift": PACKAGE.encode(), "Sources/BackendAPI/FixtureTypes.swift": API.encode()}
    original_raw, candidate_raw = original.read_bytes(), candidate.read_bytes()
    bodies["Sources/BaselineGeometry/GuestViewport.swift"] = portable(original_raw)
    bodies["Sources/CandidateGeometry/GuestViewport.swift"] = portable(candidate_raw)
    harness = Path(__file__).with_name("GeometryHotpath.swift").read_bytes()
    bodies["Sources/GeometryHotpath/main.swift"] = harness
    for name, raw in bodies.items():
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("xb") as stream:
            stream.write(raw)
    return {"schemaVersion": 1, "outputPackage": str(output.resolve()),
            "originalSourceSHA256": sha(original_raw), "candidateSourceSHA256": sha(candidate_raw),
            "harnessSHA256": sha(harness), "sourceBodyRewritten": False,
            "portabilityChange": "Conditional CoreGraphics import only; Foundation supplies CGRect on non-Apple Swift",
            "fixtureAPI": "Minimal PixelSize and VMError shapes; no error-path performance claim",
            "stagedFileSHA256": {name: sha(raw) for name, raw in bodies.items()},
            "nativeExecutionPerformed": False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("original_guest_viewport", type=Path)
    parser.add_argument("candidate_guest_viewport", type=Path)
    parser.add_argument("fresh_package_directory", type=Path)
    args = parser.parse_args()
    print(json.dumps(prepare(args.original_guest_viewport, args.candidate_guest_viewport, args.fresh_package_directory), indent=2))


if __name__ == "__main__":
    main()
