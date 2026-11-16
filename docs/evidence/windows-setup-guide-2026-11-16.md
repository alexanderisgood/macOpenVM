# Windows setup guide verification — 16 November 2026

Scope: a read-only help window and clearer driver discovery, using the existing
reviewed Windows runtime on one Apple-silicon macOS 27 development host.

- Release build, strict Swift formatting and build-provenance verification passed.
- The 24 tests in NetworkSettingsSessionTests, DesktopMediaAdmissionTests,
  WindowsNetworkEligibilityTests and WindowsCreationDraftTests passed, including
  stale requests, changed selections and rejected media/settings updates.
- Installed app and bundled worker passed strict code-signature verification;
  installed file hashes matched the newly built bundle. Installation followed
  normal VM shutdown and launcher exit; VM files were not copied or replaced.
- The selected Windows VM exposes a Windows Setup & Drivers button. Help opens
  the guide while the actual VM is running. Its saved Shared/Attached state,
  instructions and two links are exposed through native accessibility controls.
- Native scrolling reached the complete driver instructions and download links;
  the normal-size window showed readable wrapping. Closing help returned to the
  running guest. The VM retained the same process and configuration during help
  inspection.
- With the user's networking approval, the ordinary stopped settings editor saved
  Shared. The next launch used HVF, VirtIO networking and the buffered disk cache
  with guest flushes enabled. The existing reviewed driver disc was visible in
  the Windows folder picker. Selecting drivers/netkvm installed the network
  driver, and OOBE displayed **Connected** with **Next** enabled.
- The existing public VirtIO 0.1.302-1 ZIP download was fetched and its published
  SHA-256 matched. It contains the three documented ARM64 driver packages,
  license notices and per-file checksums. The ZIP was inspected, not executed.

Limits: OOBE Connected is not a detailed DHCP/DNS/TLS or throughput qualification.
The guest observation uses the existing development driver disc and does not
qualify all drivers in the public preview. Account setup remains with the user.
Small-window, keyboard-only and full VoiceOver acceptance remain pending; the
configured-state labels are currently combined by native accessibility. Creation
entry compiled but was not exercised by creating another VM. Public source still
does not supply the complete Windows runtime or an app-managed downloadable disc.
No near-native performance or additional device-coverage claim is made.
