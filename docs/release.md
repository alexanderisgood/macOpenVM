# Source preview and release scope

The public repository is a source-only alpha intended for contributors. It
contains the original app and CLI source, tests and explicitly licensed upstream
patches. It is not a supported VM product or a signed/notarized binary release.

## Build environment and validation

The source requires macOS SDK 27 with Swift 6.4 (Xcode 27 or Command Line Tools 27).
macOS 14 is the deployment target, not the required build SDK. Local development
used Command Line Tools 27, macOS SDK 27 and Swift 6.4. CI targets ARM64 macOS 27
with Xcode 27.0.

A clean public source copy passed 1,319 Swift tests on Apple silicon with the
local toolchain above. Strict formatting, generated protocol/SPDX checks, 33 portable benchmark
tests and signed debug/release builds also passed. Public CI remains pending.
Older compiler/toolchain support is unqualified; initial Xcode 26.6 runs found
compiler compatibility failures. The current CI uses the verified Xcode 27
toolchain family and retains the complete source-check suite.
Before describing a public snapshot as fully verified, record
the exact revision and toolchain and run from a copy without private development
artifacts:

```sh
./scripts/check.sh
./scripts/build.sh debug
./scripts/build.sh release
```

Record required tools, failures and explicit native-test skips. Unit tests,
generated host/GPU fixtures and real guest acceptance establish different things.
External benchmark prerequisites must be supplied separately and documented.

## Included and excluded

Original app and CLI code is [Apache-2.0](../LICENSE). Upstream patches and the
public certificate fixture retain their own file licenses and attribution; see
[NOTICE](../NOTICE). Review licenses for any additional dependency or artifact.

The snapshot excludes operating-system media, VM data, firmware and driver
binaries, private Windows runtime files, build products and private development
history. A user supplies their own lawfully obtained external software and
licenses. The current Windows development runtime is not reproducible from this
source snapshot.

The Windows screenshot shows a private development VM using VNC. Its required
binaries are excluded. It does not establish FPS, native GPU performance or HDR.
Windows HDR is unavailable; included HDR host foundations are inactive.

## Later binary releases

A binary release requires reproducible runtime source/build recipes, dependency
and license review, a complete artifact inventory, qualified guest and hardware
behavior, signing/notarization and tested installation/update/rollback behavior.
Windows guest tools, audio, HDR, sustained 120 FPS and near-native performance
remain development work. See the [feature matrix](../FEATURE_MATRIX.md).

## Validation records

The clean-copy 1,319-test result used CLT 27, Swift 6.4 and SDK 27 on an Apple
silicon Mac running macOS 27. Debug/release bundle signatures and provenance
were verified at `54ac033`; public compiler-portability fixes followed. No
private runtime or VM was supplied to these builds. The broader Python
integration suite is part of public CI and is not claimed as a completed local
check here. Current public CI results are available in the repository Actions tab.
