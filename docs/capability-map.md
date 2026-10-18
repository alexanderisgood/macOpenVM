# Public-API capability map — inspected 2026-10-06

Public SDK: CommandLineTools macOS 27 SDK, Swift 6.4. Deployment minimum remains
macOS 14. Headers were read, not private framework binaries. All runtime claims
still require evidence on the supported OS matrix.

| Requirement | Apple Virtualization.framework | QEMU/HVF candidate |
|---|---|---|
| ARM64 CPU | Same-host-architecture native virtualization; support/limit probe | Installed 11.1.0 lists hvf; explicit `-accel hvf -cpu host`; never automatic TCG fallback |
| Linux boot | VZLinuxBootLoader or EFI + generic platform | Versioned ARM virt + firmware/direct kernel |
| Windows ARM64 | No verified compliant device/TPM/driver/boot path here | Research candidate; actual installation unproven |
| Platform identity | Generic machine identifier; persistent EFI variables | Persist machine version, EFI variables, MAC and TPM state |
| Storage | Raw file attachment, virtio block | Raw/qcow2 backend; NVMe/virtio are different guest device contracts |
| Display | Virtio graphics and VZVirtualMachineView; SDK allows one scanout | Installed build has RAMFB/virtio GPU and Cocoa; no SPICE option |
| Resize/input | Automatic view reconfiguration available macOS 14; applied mode still must be checked; USB keyboard/pointer | Monitor/driver/input transport must be selected and tested; generic agent is not SPICE agent |
| Network | VZNATNetworkDeviceAttachment; bridged entitlement separate | User networking candidate; default inbound disabled; guest driver needed |
| Guest communication | Virtio socket/console, requires actual guest support | Virtio-serial or equivalent; driver and authenticated framing required |
| Audio/sharing | Virtio sound/filesystem candidates, guest support required | Device/driver/license investigation; not universal passthrough |
| Save/restore | API availability and configuration validation; not a durable disk snapshot | QMP/migration + disk coordination research; no snapshot claim |
| Secure Boot | macOS 27 SDK adds public EFI Secure Boot APIs; unavailable on 14–26 and not a Windows compatibility proof | Installed generic AArch64 firmware is not a verified secure build; protected host-variable ARM candidate and current trust/revocation chain need source/runtime audit |
| TPM | No public TPM configuration found in inspected headers | Installed swtpm 0.10.2; attachment, durable identity and security tests pending |
| 3D | No demonstrated Windows DirectX driver or guest Metal translation | Installed virtio display device does not establish accelerated Windows graphics |

Apple's [Linux guide](https://developer.apple.com/documentation/virtualization/running-linux-in-a-virtual-machine)
and [EFI API](https://developer.apple.com/documentation/virtualization/vzefibootloader)
describe the native starting point. Device bounds/availability above were also
checked in public SDK headers. QEMU's [ARM virt documentation](https://www.qemu.org/docs/master/system/arm/virt.html)
describes explicit guest devices and versioned machines. Its
[invocation documentation](https://www.qemu.org/docs/master/system/invocation.html)
describes accelerator selection. Microsoft requires native ARM64 kernel and print
drivers ([Windows on Arm FAQ](https://learn.microsoft.com/en-us/windows/arm/faq)).
Official [Windows ARM64 media](https://www.microsoft.com/en-us/software-download/windows11arm64)
exists; macOpenVM neither redistributes nor licenses it.

Current public media availability is separate from installation rights and local
acquisition. The Microsoft page advertises 26H2 ARM64 with published hashes;
no Windows ISO was downloaded here and no agreement/account/license was supplied.
Generic EDK2 and installed swtpm do not establish compliant secure boot or TPM health.
QEMU documents an ARM host-variable service with additional host attack surface;
pin firmware/device versions and prove authenticated updates, revoked-image rejection
and durable TPM identity before treating that as a Windows platform. See
[firmware evaluation ADR 6](adr/0006-arm-secure-firmware-evaluation.md) and
the source/tool prerequisite audit (private development record omitted).

Decision: Linux AppleVz experiment first; Windows QEMU/HVF research, fail closed
on missing compliant prerequisites. Secure Boot API availability on this newer
host does not justify changing the minimum OS or claiming Windows support.

The installed Homebrew QEMU 11.1.0 formula explicitly disables HVF on Apple
silicon when the host is macOS Sonoma or earlier. This newer host's binary cannot
establish the minimum-macOS-14 Windows path. Pin and evaluate a viable source/build
recipe per host OS before adoption; do not silently fall back to TCG.
