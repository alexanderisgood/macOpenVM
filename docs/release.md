# Source preview and release scope

The public repository is a source-only alpha intended for contributors. It
contains the original app and CLI source, tests and explicitly licensed upstream
patches. It is not a supported VM product or a signed/notarized binary release.

## Build environment and validation

The source requires macOS SDK 26 or later with a compatible Swift 6 toolchain.
macOS 14 is the deployment target, not the required build SDK. Local development
used Command Line Tools 27, macOS SDK 27 and Swift 6.4. CI targets ARM64 macOS 26
with Xcode 26.6.

A clean public source copy passed 1,319 Swift tests on Apple silicon with the
local toolchain above. Other clean-copy checks and public CI remain pending.
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
