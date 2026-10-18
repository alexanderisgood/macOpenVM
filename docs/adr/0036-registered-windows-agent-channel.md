# 36. Explicit registered Windows virtio-serial evaluation channel

Status: experimental source slice; real Windows device/byte-transfer acceptance
is pending. This channel records a transport location, never agent health.

The registered Windows plan currently has QMP, TPM, display and worker endpoints.
Windows guest integration needs a separate byte transport. Choose an explicitly
reviewed, non-serialized `virtioSerialV1` selection, absent by default, on both
launch resources and endpoints. The selections must agree. No untrusted VM
configuration flag or ordinary CLI/UI action enables it. Existing ordinary
launches retain their exact argument sequence when selection is absent.

The selected recipe uses the existing retained QEMU process and one private
Unix listener in its pinned endpoint directory:

```
-device virtio-serial-pci,id=agentserial0,disable-legacy=on,disable-modern=off,max_ports=2
-chardev socket,id=agentchr0,path=<private directory>/agent.sock,server=on,wait=off
-device virtserialport,id=agentport0,bus=agentserial0.0,nr=1,chardev=agentchr0,name=org.macopenvm.agent.v1
```

Port zero is reserved for a console in the retained QEMU implementation. Use
port one and the exact public named-port convention expected by the existing
original Windows metadata evaluator. This is independent of a NIC. There is no
TCP listener, QEMU TLS, telnet, multiplexing, hotplug, guest content logging or
new child process. Keep existing platform, durable disk, TPM, support carrier,
network and runtime ownership rules.

The agent endpoint shares the existing bounded path and original-parent checks;
it must be absent before child launch. After actual running/owned status, a
selected runtime can publish one bounded private `agent.json` containing the
VM/session and control/agent paths plus pinned parent/socket device/inode.
Publication requires the selected socket and refuses indirect or changed
parents, non-sockets and existing route files. It does not connect a host
client, install a driver, verify TLS, or alter custody settlement.

Acceptance for this source slice: exact absent/selected argument tests,
mismatched selection refusal, preserved NAT/carrier/platform arguments,
private real socket and parent identity tests, bounded exclusive publication,
strict formatting and isolated build. Native acceptance then needs a fresh
explicitly selected runtime, actual signed vioser loading, unique named-port
metadata and fragmented/short-transfer/disconnect/cancellation proof. Existing
live VMs are not modified to attach this device.

The existing Windows diagnostic uses the public vioser interface GUID and INFO
IOCTL; it currently performs metadata inspection rather than a health exchange.
Next implement a separate bounded console transfer evaluation over the reopened
exclusive overlapped handle. Terminal native completion must precede buffer,
event or handle release. A cancellation request, timeout or missing completion
is not a completed operation.

Before managed guest integration, the host needs repeated registered endpoint
identity/session admission, actual TLS cancellation/drain observation, Windows
TLS 1.3 credential hosting and scoped mutual peer verification. The generated
Hello/Health schema already exists. Combined installer, elevation, service/user
separation, credential enrollment, upgrade/rollback and verified installation
health remain separate requirements. No plaintext health or weaker trust path
is introduced.

Source acceptance passed 25 focused checks (16 backend, 7 worker, 2 recovery),
strict formatting and independent review. Private evidence
`.lab/registered-windows-agent-channel-tests-ff9abc56c0aa488194162a743c80f37d/result.json`,
SHA256 `3980203b3a622c453db177bce0b28aaddb7ed27cfd63572e4f41900e184e3af8`.
The first restricted run failed existing/new private socket bind fixtures and
remains failed; the same built checks passed with local test access. No native
QEMU device, Windows driver, TLS or guest health action occurred. Build and fresh
native activation remain distinct acceptance steps.

The original fixed transfer evaluator (private development record omitted)
now passes portable fragment/custody tests, sanitizer checks, independent native
adapter review and deterministic ARM64 static builds. It has not executed in
Windows. These prerequisites do not promote driver/TLS/installation health.

An explicitly named `windows-agent-worker-lab` caller now selects only the closed
`fixed-transfer-evaluation` argument before runtime I/O. Ordinary `windows-worker`
continues with no channel. The next native prerequisite uses a new original
empty, offline no-OS registration to verify actual QEMU device acceptance and
private route publication without claiming Windows driver or agent behavior.
