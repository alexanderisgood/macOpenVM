# Generated HDR host transport fixture

This finite Apple Silicon macOS fixture tests the actual production host client,
C transport and FP16 renderer. It never chooses a registered app, VM, existing
socket or guest resource, and never activates its hidden generated window.

First build the normal production `Qemu` and `SharedFrameWire` targets with the
repository's qualified macOS 14+ toolchain. The build directory must contain
the normal Xcode products (`Qemu.o`, `SharedFrameWire.o`, `BackendAPI.o`,
`VMStorage.o` and their real Swift module directories) from the current source.
Then run, with absolute paths:

```sh
python3 Benchmarks/HDRHost/run.py \
  --build-directory /ABSOLUTE/actual-build/Products/Debug \
  --sdk /ABSOLUTE/MacOSX.sdk \
  --clang /ABSOLUTE/toolchain/usr/bin/clang \
  --swiftc /ABSOLUTE/toolchain/usr/bin/swiftc \
  --output-directory /ABSOLUTE/new-hdr-host-run
```

The output directory must not exist. The runner freezes and hashes real backend
objects/modules, C headers and production source. It links actual `Qemu.o` and
`SharedFrameWire.o`; it does not recompile copied backend implementations or use
standalone substitute types. Only the exact production App renderer/profile
sources are compiled beside the generated oracle, with Swift 6 strict concurrency
and warnings as errors. The explicit target is macOS 14 ARM64. Input hashes alone
do not prove that existing build objects were built from current source; the
qualified build and its provenance remain a prerequisite.

Each compile and paired process has retained direct-child ownership, bounded
logs, real EOF/reap checks and a finite watchdog. After timeout it signals only
that exact child, records every signal, and fails qualification. Three pairs use
fresh 0700 temporary directories: positive, duplicate backing and still-named
shared-memory rejection. A consumer starts only after the producer's exact READY
line and an owned socket check. Failed endpoints/logs are retained for diagnosis;
do not rerun a test against an existing runtime socket.

A passing positive pair proves actual readonly POSIX-shm FD admission, separate
frozen-borrow/latest slots, exact ATTACH/FRAME ACKs, actual GPU-copy-driven ACK,
and two different 31×3 padded FP16 snapshots through the private cache and real
shader. Every row/column/corner uses distinct non-palindromic half-bit values;
negative and above-one RGB survive, while alpha becomes opaque 1. Both negative
producers require peer close before any ATTACH ACK. Source and artifact pins,
commands, logs, process receipts and final `result.json` are retained.

This does **not** qualify Windows HDR, source color authority, source GPU fences,
writer exclusion, target transforms, physical luminance, on-screen presentation,
resize/visibility/cancellation failures or FPS. The renderer stays inactive for
screen presentation; hidden layer attachment checks EDR configuration only.
The production classes have no controller caller or automatic endpoint selection.
Those integration stages require their own actual failure and live validation.
