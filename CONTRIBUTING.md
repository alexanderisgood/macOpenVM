# Contributing

macOpenVM is a source-only alpha. Contributions should make a concrete behavior
work, make failures safer, or improve reproducible evidence. Coordinate larger
changes in a [project issue](https://github.com/alexanderisgood/macOpenVM/issues).

## Development setup

Use an Apple silicon Mac, macOS SDK 27, Swift 6.4
and Python 3. The deployment target is macOS 14; building against an older SDK
does not provide the glass UI APIs used by the source. Local development used
Command Line Tools 27, macOS SDK 27 and Swift 6.4. CI targets ARM64 macOS 27 with Xcode 27.0.
The clean source copy passed 1,319 Swift tests, portable benchmark tests,
format/protocol/inventory checks and signed debug/release builds. See the [hosted checks](https://github.com/alexanderisgood/macOpenVM/actions/workflows/ci.yml)
for current CI results; older compiler/toolchain support is unqualified.

Run `./scripts/check.sh`, then `./scripts/build.sh debug` and
`./scripts/build.sh release`. Describe the toolchain, results and explicit skips
in your pull request. Native guest, GPU and hardware tests require their documented
prerequisites and explicit opt-in. Prefer generated fixtures for routine tests.

The full check includes exhaustive Linux agent recovery fault matrices and can
be slow on macOS. CI runs these in sixteen isolated Linux shards; the remaining
checks and both app builds run on macOS. To reproduce a Linux shard, run
`python3 scripts/check-integration.py --group linux-agent --shard-index 0 --shard-count 16`.
The default `./scripts/check.sh` still selects the complete integration suite.
Recovery fault boundaries are individual tests so every boundary can be
distributed across the matrix; each process verifies the complete trace inventory.

## Useful contributions

- Reproducible Windows runtime builds with pinned sources, licenses and recipes.
- Graphics performance fixes backed by repeated, comparable measurements.
- Audio implementation and actual playback validation.
- HDR source identity, synchronization, color and presentation integration.
- Cancellation, resource ownership, storage and lifecycle failure tests.

Keep changes focused. Explain the problem, resulting behavior, validation and
remaining limits. Preserve VM identity and user data; include failure cases when
changing lifecycle or storage operations. Follow the existing Swift 6 concurrency,
warnings-as-errors and formatting rules.

Separate unit tests, generated GPU fixtures, private guest observations and public
reproduction. A successful build or high refresh mode does not establish guest
FPS, physical presentation, HDR output or a supported product feature.

## Source and reports

Original contributions use Apache-2.0. Preserve the license and attribution of
upstream patches and fixtures, and document new dependencies. Do not include OS
media, VM disks, third-party binaries, credentials, private logs or personal paths.

For bugs, provide a minimal reproduction, source revision, toolchain and a
redacted error. Use [SECURITY.md](SECURITY.md) for sensitive reports and follow
the [code of conduct](CODE_OF_CONDUCT.md).
