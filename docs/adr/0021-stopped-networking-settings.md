# ADR 21: explicit stopped networking settings

Status: accepted for the experimental native Linux path.

Creation already persists disconnected/shared mode and a stable MAC. A separate
networking editor is needed for saved VMs. Shared mode is an explicit grant of
outbound access to the host's local network and internet; editing a stopped VM
does not start traffic or change a running guest.

Use a separate Liquid Glass draft and `set-network --directory … --network
disconnected|shared`. Shared edits require Linux/AppleVz. Disconnected metadata
may be saved for other configurations without qualifying their runtime. Both
app and CLI use NetworkSettings with the same cooperating writer admission.

Replace only the existing network JSON scalar. Preserve all other registration
bytes, VM/MAC identity, disks and platform state. An actual change creates an
exclusive private exact configuration backup, flushes it, atomically replaces
registration, flushes its directory and reads back both files. No-op saves create
no backup. A partial failure preserves evidence and requires reopening the saved
selection. Pending runtime/storage transactions and inherited ownership cannot
authorize a settings save. The UI passes its original configuration to reject a
stale draft and disables conflicting actions while editing or saving.

Do not combine hardware and networking as two successive saves behind one Save
button: that would falsely imply one atomic settings operation. Do not alter
firewalls, create helpers or incoming listeners, enable bridge/forwarding controls,
or regenerate MAC identity as part of a mode change. Public AppleVz configuration
omits NICs when disconnected and constructs one virtio NAT NIC with the saved MAC
when shared; connectivity evidence remains separately scoped.

Acceptance for this slice: exact off/shared/off transforms and backups; disk,
identity and unrelated metadata preservation; no-op/stale/held/inherited writer
rejection; pending intent/growth and uncertain commit tests; actual CLI saves;
native sheet save/cancel and next-start device application. Broader NAT inbound
exposure, DHCP/DNS variants, reconnect, Windows and minimum-host qualification
remain under ADR 4 and the feature matrix.
