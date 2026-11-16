# Windows runtime dependency refresh, 16 November 2026

A host Homebrew update removed six library paths expected by the private Windows
runtime. The ordinary creation command and app correctly refused the obsolete
catalog. The current development catalog pins GLib 2.90.1 (four dylibs),
libunistring 1.5 and PCRE2 10.49, including exact sizes, hashes, import aliases and
GLib's internal versioned dependency paths.

Installed Homebrew/core bottle receipts, ARM64 Mach-O imports and signatures were
inspected. Ordinary full resource verification then admitted a fresh Windows VM
with eight vCPUs, 16 GiB memory and an 85 GiB sparse disk. Initial allocated disk
bytes were zero. The app's hardware editor showed the saved values and its new
recommendation control. The reviewed driver disc attached through the ordinary
stopped-VM action. The ordinary app Start action launched firmware and the
official ARM64 Windows installer reached its language and keyboard screens.
Installer keyboard input worked; the interactive setup was handed to the user.

The 22 registered-runtime tests, strict formatting, release build, packaged
provenance and installed signature/file checks passed. No resource verification
check, signature requirement or minimum host requirement was removed. Creation
identity pins (QEMU, firmware, TPM executable and keymap) are unchanged. Existing
VM disk, EFI and TPM identities do not need rewriting for this library refresh.

This remains a specific macOS 27 development runtime. These external libraries
are not bundled with the public source. Other Homebrew versions need their own
reviewed catalog; this is not a portable dependency resolver, cross-device
qualification or Windows workload performance result. Exact bottle reproduction
and complete release licensing/security review remain pending in the inventory.
