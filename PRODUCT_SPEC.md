# Product specification

## Users and scope

Serve Mac users who need a responsive Windows ARM64 desktop, Linux development
environments, and recoverable VM workflows without proprietary runtime software.
The full objective is evidence-backed feature and performance parity with mature
desktop virtualization tools. A boot experiment or first stable release is an
intermediate milestone, not completion of that objective.

Original interface, terminology, implementation and assets; documented Apple
APIs and properly licensed dependencies only. Original code is Apache-2.0.
Minimum host macOS 14; Swift 6 strict concurrency; SwiftUI/AppKit UI.

The user requires a Liquid Glass interface. Use native public SwiftUI Liquid
Glass on macOS 26 and later for navigation, status and interactive controls.
Keep installation forms, explanations and guest pixels readable, with a solid
semantic-color fallback for Reduce Transparency or Increased Contrast. macOS
14–25 retains native material/bordered controls behind availability checks;
it cannot provide the newer system Liquid Glass material. No decorative motion
or simulated refraction is required. Preserve native window, focus and keyboard
behavior, and verify both light and dark presentation and accessibility.

## Host and guest matrix

| Host | Guest | Backend decision | Current claim |
|---|---|---|---|
| Apple silicon, macOS 14+ | ARM64 Linux | AppleVz initial experiment | Experimental; runtime evidence required |
| Apple silicon, macOS 14+ | Windows 11 ARM64 | QEMU/HVF candidate | Blocked pending compliant firmware, TPM, drivers and media |
| Intel Mac | x86/x64 | Separate backend evaluation | Planned, unverified |
| Apple silicon | x86/x64 OS | Separate emulation evaluation | Planned; no native-speed claim |

The development host is macOS 27.0 build 26A428, Mac17,8, M5 Pro, 48 GiB,
18 logical CPUs. That does not verify macOS 14 or other physical Macs.

## UX flows

1. First launch shows host capabilities and actionable missing prerequisites.
2. Library → New VM → user-selected ARM64 media → conservative hardware defaults
   → explicit network/sharing policy → validated creation → installation window.
3. Starting a VM hides the library. Machine/View/Input menus remain accessible;
   reopening the library is deliberate. Destructive actions require confirmation.
4. Guest setup uses one support disc and one installer entry point. Completion
   requires an authenticated handshake and healthy installed components.
5. Errors preserve disks and last good metadata; diagnostics redact secrets and
   private guest content. Recovery never silently force-stops a VM.

Until their backend works, controls are hidden or clearly experimental. No
telemetry, automatic downloads, implicit LAN exposure, or automatic sharing.

## Desktop acceptance

Discover live logical viewport/backing scale/guest pixels and validate applied
guest mode. Maintain one pointer transform and release held input on focus loss.
Test physical and synthesized keyboards, UK/US mappings, repeated keys and IME.
Use AppKit fullscreen and app-scoped Dock presentation without cropping the guest
taskbar or creating a second owning window. Accessibility, high contrast, reduced
motion and keyboard navigation are release gates. Windows desktop interaction
targets measured 120 FPS at the host display's native resolution on a named
host, with exact applied guest dimensions, sustained rendered/presented rates and
median/p95 input latency. The earlier60Hz milestone remains intermediate; no120FPS
claim is made until rendering, transport and host presentation measurements pass.

## Stable release gates

Windows 11 ARM64 and one mainstream ARM64 Linux distro must install and work
entirely through the GUI on a precise hardware/OS matrix. Lifecycle, storage,
NAT, display, input, CLI, diagnostics and recovery must pass documented tests.
Advertised integrations must pass authentication, malicious-input, reconnect and
upgrade tests. Snapshots require integrity campaigns or are omitted from stable
claims. No unresolved known high/critical issue. Accessibility and security review,
reproducible clean-machine builds, signing/notarization, checksums, SBOM, licenses,
known limitations and uninstall instructions are mandatory. Publish raw benchmarks.

## Non-goals and boundaries

No proprietary disk-format compatibility without public specifications and
independent tests. No private APIs, copied competitor UI, universal USB support,
security bypasses, bundled OS keys/media or context-free speed claims. Advanced
graphics and genuine per-window seamless mode remain on the full objective ledger.
The maintainer's controlled release bundle namespace is not yet supplied;
`local.macOpenVM` is only a development identifier.
