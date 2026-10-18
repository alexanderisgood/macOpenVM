# ADR 31: stopped Windows installation preparation

Status: source, ordinary offline App driver-disc action and normal CLI file-only preparation verified; runtime installation and networking remain experimental.

The ordinary Windows app now starts a registered offline VM. Guided installation
still requires the reviewed network driver disc and an explicit shared-network
choice. A generic tools-image picker is misleading when the worker accepts only
one independently reviewed image. Replace that Windows action with attachment of
the fixed, verified driver disc. Retain the existing Linux chooser, one support
image field, Liquid Glass controls and accessible labels. Give accurate manual
Windows Install driver instructions; attachment does not run an installer or
establish driver health. The production combined agent/driver setup disc remains
required and unimplemented for Windows.

Verify the carrier off the UI actor, retain busy state across verification and
recheck the selected configuration/directory before saving. Media updates accept
an optional expected configuration, checked before inspection/backup and again
under the actual writer lock. Existing callers default to no additional expected
selection. Re-evaluate Windows readiness through the common closed catalog after
selection so an unreviewed support path cannot look ready to launch.

Shared-network preparation uses a non-serialized permission bound to the exact
baseline configuration. Only package source can construct it. The QEMU factory
projects the shared choice and verifies the independently reviewed runtime,
Hypervisor entitlement, signatures, imports, loader libraries and optional carrier.
Configuration supplies no hashes, executables, arguments or capability flags.
Core and the storage transaction require matching permission for the precise
Windows/QEMU/ARM64/EFI case; default callers still reject unreviewed Windows shared
mode. Native Linux behavior remains unchanged. This permission permits a desired
configuration save, not network execution, installation, compatibility or consent.

The normal CLI can prepare shared networking on a stopped reviewed Windows VM,
using the existing actual writer/intent/growth exclusion, surgical scalar update,
exclusive prior-byte backup and atomic commit. Preserve MAC/VM identity, creation
provenance, disk, firmware variables and TPM. Validate lexical local paths without
rewriting macOS `/private/tmp` aliases. Public Windows shared-mode UI and Start
remain gated until a separately authorised fresh runtime trial passes.

Acceptance: stale media selections reject before backup/mutation; no/wrong network
permission rejects; stopped shared/no-op/disconnect preserves exact registration
bytes and protected identities; held/unsettled/stale/fault paths retain their
existing guarantees. Actual read-only catalog checks and normal CLI file-only
preparation must start no VM, driver or network. Next prepare a fresh trial, then
obtain any needed execution approval for driver loading, DHCP/DNS/verified outbound
access, normal shutdown and cold boot. Prior A5C permission remains specific to
that installed VM. Full GUI installation, physical input and daily use stay open.

Root93139 passed90 focused Swift registrations and actual read-only resource checks;
five parent guards passed. Root27540 passed the ordinary App driver-disc action,
offline startup/SDK rendering and explicit forced settlement. Root40247 passed
normal CLI shared/no-op/disconnect byte/identity preservation without any network.
See evidence (private development record omitted).
