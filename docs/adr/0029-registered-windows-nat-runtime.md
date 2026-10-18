# ADR 29: independently reviewed Windows NAT runtime

Status: source and actual resource checks qualified; ordinary Windows shared mode remains gated.

Windows guided installation needs explicit network access. The ordinary registered
worker currently uses the reviewed offline QEMU executable; the earlier approved
installation used a separate SLIRP-enabled executable. A saved network choice
must not select an executable, modify firmware identity or confer runtime trust.

Extend the non-serialized reviewed launch resources with an independently supplied
runtime QEMU resource and a code-reviewed shared-network capability. Existing
callers default to the original creation executable and no shared capability.
The saved platform record continues to bind the same four creation provenance
resources, VM identity, variables and TPM directory. It stays byte-for-byte
unchanged when a future stopped VM changes its desired network mode.

Actual launch and revalidation check the selected runtime executable's exact
bytes, ARM64/Mach-O imports, host floor, signature and Hypervisor entitlement,
plus every reviewed loader library and alias. Repeat pinned-byte checks after
signature validation. A separate shared catalog needs independent review of the
retained SLIRP candidate and its relocated private libslirp closure before use.
Neither configuration nor a platform JSON record can supply the override.

Disconnected mode retains `-nic none`. Shared mode requires the reviewed capability
and constructs one fixed IPv4 user network and one modern virtio-net PCI device.
Reuse the existing canonical locally administered unicast MAC from configuration.
The fixed DHCP subnet, host gateway and DNS proxy are `10.0.2.0/24`, `10.0.2.2`
and `10.0.2.3`; the DHCP range starts at `10.0.2.15`. Outbound access follows host
routes and includes the LAN. The retained candidate disables guest access to host
loopback through public libslirp configuration. No host/guest forwarding, SMB,
TFTP, TAP, bridge, firewall changes or incoming service are added.

Creation remains disconnected by default. Saving shared mode will reuse the
existing stopped-only writer/settled-intent/configuration-backup transaction only
after the new launch/driver path is qualified. It replaces the network scalar
without regenerating VM/MAC identity, disk, firmware variables or TPM state.
The current shared picker and ordinary Windows shared Start remain disabled.

[ADR31](0031-stopped-windows-installation-preparation.md) refines this ordering:
the CLI may prepare the desired shared scalar after independently verified catalog
admission through an exact-baseline non-serialized permission. This creates no
network or VM; actual execution still needs its own authorisation and qualification.
Public Windows shared-mode UI and Start remain gated.

Acceptance proceeds through source tests for capability refusal, exact NIC/MAC
arguments, unchanged compute/storage arguments, selected-runtime signature/import
and byte drift, and unchanged platform/state bytes. These checks launch no guest
or network. Next independently review the shared catalog and a bounded read-only
driver-carrier seam, then explicitly authorize a fresh registered Windows trial
for real driver loading, DHCP/route/DNS/verified outbound access, normal shutdown
and cold boot. The earlier A5C installation consent does not authorize new trials.
Connectivity, incoming exposure, performance, older hosts and release closure
remain separate gates.


The independent shared catalog and runtime/recipe APIs are implemented. Root58773 passed32focused registrations, including actual read-only signature/loader verification of both catalogs and real file/lease/state preservation cases. The initial test macro compile failure is retained and corrected without production changes. This qualifies the source/resources only; no new network or guest was launched. See evidence (private development record omitted).
