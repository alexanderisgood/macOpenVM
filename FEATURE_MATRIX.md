# Feature matrix

This describes a source-only alpha. "Implemented" identifies source functionality,
not a support or compatibility guarantee. Local development evidence does not
replace a clean public build or native acceptance on another Mac.

| Area | Current state | Public snapshot limits |
|---|---|---|
| macOS app and CLI | Original Swift implementation | Clean public-snapshot checks and public CI pending |
| Apple silicon / macOS | macOS 14 deployment target | Build requires SDK 26+ and a compatible Swift 6 toolchain |
| ARM64 Linux | Native Virtualization backend; local boot and desktop experiments | Guided installation and broad guest compatibility unfinished |
| VM library | Create/open, recent locations and settings UI implemented | Experimental user interface |
| Storage and lifecycle | Identity, ownership, stopped operations and failure checks implemented | Not power-loss or universal filesystem qualification |
| Windows 11 ARM64 | Runs in a private development environment | Pinned Windows runtime, firmware and drivers are not supplied |
| Windows accelerated graphics | Private GPU experiments and host display code | Reproducible public runtime recipe unfinished |
| VNC display and input | Host implementation and generated tests | Screenshot uses a private Windows environment |
| Integer scaling | Backing-pixel viewport geometry implemented | Host presentation setting; no guest resolution change |
| Light sharpening | Optional and off by default | Measurable GPU cost; FPS neutrality unqualified |
| Audio | Experimental private evaluation | Supported playback and latency qualification unfinished |
| HDR | Inactive host transport, FP16 rendering and validation foundations | No working Windows HDR path or HDR output claim |
| Guest tools | Protocol and transport experiments | Guided Windows tools installation unfinished |
| Performance | Scoped fixtures and local measurements | Sustained 120 FPS, near-native and game performance unqualified |
| Distribution | Original source under Apache-2.0; upstream file licenses retained | No OS media, VM data or third-party runtime binaries |
| Signing | Local ad hoc development builds | No signed/notarized binary release |

The existing development checkout passed 1,319 Swift tests. Fresh-copy checks,
public CI, real guest acceptance and controlled graphics comparisons are separate
results. See [contributing](CONTRIBUTING.md) and [release scope](docs/release.md).
