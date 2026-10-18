# ADR 24: Windows ARM64 agent transport evaluation

Status: experimental candidate; Windows driver loading and communication untested.

Evaluate the existing QEMU `virtio-serial-pci` / `virtserialport` devices with a
released Windows 11 ARM64 vioser driver and a private Unix chardev. This keeps
agent traffic independent of a guest NIC. The driver exposes a Windows device
HANDLE interface; it must not be assumed to be a COM port. The existing generated
bounded protocol remains shared with the host and Linux implementation.

Offline candidate verification (private development record omitted)
now establishes released ARM64 SYS/INF/CAT bytes, Microsoft signature/timestamp
chains and exact catalog member bindings. That does not establish current
revocation, Windows code-integrity policy, guest device loading, cancellation,
named-port I/O, TLS or least-privilege service access. The live Windows installer
and its pinned runtime are preserved; this investigation adds no devices to it.

The next small build slice uses original C and public Win32 APIs, overlapped
exclusive HANDLE I/O and native Schannel TLS 1.3. Verify the cross-build closure
and generated codec before implementing the authenticated console evaluator.
The first static ARM64 build (private development record omitted)
now passes strict diagnostics, native-only imports and two identical local builds;
the program has not executed on Windows.
An original restricted service and separate interactive per-user agent follow
only after the actual console exchange and device access policy are proven.
Per-VM enrollment remains separate from generic release media.

Tagged mm322 vioser creates exclusive raw ports with
`SDDL_DEVOBJ_SYS_ALL_ADM_ALL`; stock access is System/Administrator, not an ordinary
user or LocalService grant. The first console transfer must therefore be explicitly
elevated and labelled accordingly. Preserve its ACL and Windows protections. A
restricted production service needs its own narrow access/broker proof.
[Driver source](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/mm322/vioserial/sys/Port.c#L298).

Use public port GUID `6FDE7521-1B65-48AE-B628-80BE62016026` and current
`IOCTL_GET_INFORMATION=0x222002` (METHOD_OUT_DIRECT). The ARM64 standard layout has
Id at offset 0, flags at 4/5/6 and variable ASCII Name at 7, fixed size 8.
Static-assert the ABI and validate returned count/NUL/exact intended name within
a bounded buffer. Discovery uses documented SetupAPI interfaces, not COM-port
assumptions. Every overlapped operation owns its buffers/event until actual
completion; CancelIoEx requests cancellation without completing it. Port connection
bits are not TLS or agent-health evidence.
[Public interface](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/mm322/vioserial/sys/public.h#L35),
[cancellation contract](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-cancelioex).

Stock QEMU USB serial emulates a vendor FTDI device, without demonstrated Windows
ARM64 inbox binding. A new CDC-ACM device would add a QEMU implementation and
distribution burden; defer it while a released VirtIO serial candidate exists.
Default ARM PL011 and PCI serial also lack verified Windows ARM64 binding here.
No driver-free or universal transport claim follows from those device names.

Acceptance: reproducible ARM64 PE build with named native imports; ordinary
Windows policy loads the exact driver without disabling protections; discover
only the intended port; bounded fragmented bidirectional I/O and cancellation;
unknown-peer rejection and authenticated Hello/Health; disconnect/reconnect and
service restart; explicit install/uninstall; no NIC, credential leaks or changes
to existing VMs. Source, signing, redistribution and one-disc setup closure are
separate release gates. Continue the full Windows GUI installation acceptance.

Exact immutable interface/handler source is now retained (private development record omitted), with Git object verification and the publisher's b302/mm322 association. Corresponding source-RPM/binary reproduction and redistribution closure remain open. The next original executable evaluates discovery and the information IOCTL only, with bounded returned-count/name parsing and actual overlapped completion ownership. No raw port transfer, TLS, service or health claim follows from this step. Opening a candidate may change its connection bit; describe the scope accurately.

The original ARM64 metadata diagnostic now builds reproducibly (private development record omitted), with exact native imports and13 portable bounds/ownership contracts. It opens with zero desired access for the FILE_ANY_ACCESS information IOCTL, while preserving the driver's ACL and exclusive sharing. Actual Windows driver/device/elevation/cancellation remains unqualified. Default console close/logoff/shutdown can terminate the process; no bounded cleanup promise follows from CancelIoEx or the metadata scan budget.
