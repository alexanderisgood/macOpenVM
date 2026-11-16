# Feature matrix

This describes a source-only alpha. "Implemented" identifies source functionality,
not a support or compatibility guarantee. Local development evidence does not
replace a clean public build or native acceptance on another Mac.

| Area | Current state | Public snapshot limits |
|---|---|---|
| macOS app and CLI | Original Swift implementation; public macOS source CI passes | Real guest and hardware gates are separate |
| Apple silicon / macOS | macOS 14 deployment target | Build requires SDK 27+ and a compatible Swift 6 toolchain; current Windows runtime requires macOS 27 |
| ARM64 Linux | Native Virtualization backend; local boot and desktop experiments | Guided installation and broad guest compatibility unfinished |
| VM library | Create/open, recent locations and settings UI implemented | Experimental user interface |
| Storage and lifecycle | Identity, ownership, stopped operations and failure checks implemented | Not power-loss or universal filesystem qualification |
| Windows disk I/O | Buffered writes preserve guest flushes and discard; [disposable block fixture](Benchmarks/STORAGE.md) passes | Avoids macOS synchronous-write fallback; Windows throughput and native-speed parity remain unmeasured |
| Windows 11 ARM64 | Runs in a private development environment; fresh installer boot verified after [runtime refresh](docs/evidence/windows-runtime-refresh-2026-11-16.md) | Pinned Windows host runtime and firmware are not supplied; basic ARM64 guest drivers have a separate preview download |
| Windows setup help | Read-only guide from creation, selected VM and Help; [native guide/network observation](docs/evidence/windows-setup-guide-2026-11-16.md); links the ARM64 driver preview | Guest installation remains manual; public Windows runtime/disc packaging remains incomplete |
| Windows accelerated graphics | Private GPU experiments and host display code | Reproducible public runtime recipe unfinished |
| Windows resource defaults | App/CLI share host-sized CPU/RAM recommendations; hardware editor can apply them | Capacity and override tests pass; live workload tuning remains pending |
| Shared display copy | Direct buffer-to-texture blit; generated padded/1080p/native/4K pixel tests | Tested on one M5 Pro; no Windows FPS or cross-device support claim |
| VNC display and input | Host implementation and generated tests | Screenshot uses a private Windows environment |
| Integer scaling | Backing-pixel viewport geometry implemented | Host presentation setting; no guest resolution change |
| Light sharpening | Optional and off by default | Measurable GPU cost; FPS neutrality unqualified |
| Audio | Experimental private evaluation | Supported playback and latency qualification unfinished |
| HDR | Inactive host transport, FP16 rendering and validation foundations | No working Windows HDR path or HDR output claim |
| Guest tools | Protocol and transport experiments | Guided Windows tools installation unfinished |
| Performance | Scoped fixtures and local measurements | Sustained 120 FPS, near-native and game performance unqualified |
| Distribution | Original source under Apache-2.0; upstream file licenses retained | No OS media, VM data or third-party runtime binaries |
| Signing | Local ad hoc development builds | No signed/notarized binary release |

The development checkout passed 1,336 Swift tests. The macOS job in
[public source CI](https://github.com/alexanderisgood/macOpenVM/actions/runs/43875439404)
passed its source checks and debug/release builds. Linux recovery shards, real
guest acceptance and controlled graphics comparisons are separate results. See
[contributing](CONTRIBUTING.md) and [release scope](docs/release.md).

Windows guest-tools preparation and the native ARM64 combined installer are under
qualification; network, communication and profile-matched graphics share one UI. See
[ADR 65](docs/adr/0065-guest-tools-installer.md). Not yet qualified for release.
