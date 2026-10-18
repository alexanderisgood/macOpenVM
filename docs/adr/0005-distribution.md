# ADR 5: development signing and independently reproducible dependencies

Status: development accepted; public release blocked.

One primary macOpenVM.app, one CLI, one build entry point. Ad hoc signing with
only virtualization entitlement permits local experiments; it is not notarization.
Use local.macOpenVM temporarily; require a maintainer-controlled stable namespace
before release. Do not adopt an unowned reverse-domain identifier.

SwiftPM's internal desktop build product is macOpenVMDesktop: macOpenVM and
macopenvm collide on a case-insensitive macOS filesystem. Packaging exposes only
macOpenVM.app (visible name macOpenVM) and macopenvm. This avoids mismatched module
scans and does not introduce another user-facing application.

The build wrapper keeps caches in .build and locates the installed testing macro
plugin. SwiftPM manifest sandboxing is disabled for this original dependency-free
manifest in restricted environments; no external plugin/package executes.

The local macOS 27 CLT SDK declares a newer SwiftUI State macro but omits its
SwiftUIMacros plugin. The creation form uses the established ObservableObject /
StateObject path available on macOS 14 rather than requiring a new toolchain or
private plugin. External linker search-path warnings from this CLT installation
are recorded separately from strict project-owned compiler diagnostics.

Installed Homebrew QEMU/EDK2/swtpm are evidence tools, not redistributable project
assets or a reproducible release dependency. Record actual versions and provenance,
then pin reviewed sources/build recipes and generate a complete transitive SBOM
before bundling. A subprocess or optional switch does not resolve GPL obligations.
Reject binaries extracted from another application's bundle. Release credentials
stay outside source and PR jobs. See legal-and-distribution-risks.md.
