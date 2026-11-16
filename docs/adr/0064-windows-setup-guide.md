# 64. Windows setup and driver guide

Status: implemented experimentally; [bounded verification](../evidence/windows-setup-guide-2026-11-16.md) passed.

Windows OOBE can ask for a network driver while the VM is disconnected. That
mode creates no adapter, so installing NetKVM alone cannot provide connectivity.
Existing instructions are hidden in VM details and unavailable beside the running
guest. The public ARM64 driver preview is also separate from the source tree.

Provide one read-only, scrollable setup window, reachable from Help, the Windows
creation screen and the selected Windows VM. It remains available while the guest
runs. Show the selected VM's configured network/disc state, without inferring
driver health or connectivity. Explain the stopped settings sequence, guest
Install driver picker and drivers/netkvm folder; do not assume a drive letter.
Link the existing licensed driver preview and a concise public setup guide.

Opening help never changes configuration, attaches media, stops a VM, enables
networking or installs drivers. Existing reviewed-resource and stopped-owner
checks remain authoritative. Public source builds still require the separately
qualified Windows runtime; the driver download does not supply that runtime.

Acceptance: D11 in verification.md. Compile under strict concurrency, exercise
existing network/media admission tests, and inspect help at normal and small
window sizes. Opening help during a running VM must preserve its process and
configuration. Full guest connectivity and cross-device coverage remain separate.
