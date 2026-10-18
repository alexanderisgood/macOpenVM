# ADR 18 — Saved VM references in the native library

Status: implemented and experimentally tested for preferences, selection and session policy; native interaction remains pending.

The desktop currently selects only one configuration and forgets it when the app
exits. Add a bounded recent library of user-opened or newly created VMs, with
search, Windows/Linux groups and working open/settings/remove-reference actions.
This is navigation metadata; VM configuration, identity, disks and runtime
ownership remain authoritative at their existing locations.

Use a versioned bounded document in the app's own UserDefaults domain. Store only
configuration URL, expected VM UUID, display name and guest type. No scan, automatic
launch, thumbnails, guest content, credential, or network operation is introduced.
Keep at most 50 most recently opened references. Corrupt/future preferences are
preserved and surfaced; opening a VM independently remains available. Removing a
reference never removes files. No cross-process transactional catalog guarantee
is claimed; the single primary application owns this navigation preference.

Reopening rereads bounded metadata and verifies the stored VM UUID, with normal
configuration validation. A replaced identity must be selected explicitly through
the file picker. Windows entries can be inspected and edited, while the existing
Windows runtime admission gate remains intact. Saved entries never claim a live
runtime state; only the actual current session may show running/paused state.

Show the library through an explicit menu/shortcut and a sheet over the existing
owning window. Opening it releases guest input and does not detach or replace the
guest surface. VM selection is disabled while the current owner is busy. No edge
hover behavior, extra owning window or global presentation preference is added.

Acceptance: preference round trip, corruption preservation, bounded deduplication,
search/groups, exact-path identity checks with real configuration files, safe
forget, unchanged runtime admission, strict Swift build/tests and native visual,
keyboard, accessibility and guest-window continuity checks. Thumbnails and wider
context actions stay on the requirements ledger.

References: Apple's [UserDefaults documentation](https://developer.apple.com/documentation/foundation/userdefaults)
and [required-reason API declarations](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
The packaging manifest declares app-owned defaults use (CA92.1); this is not a
complete release privacy or App Store audit.
