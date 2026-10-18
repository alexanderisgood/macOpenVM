# Threat model

Assets: host/guest files, VM identity/TPM, credentials, host UI/input, isolation,
availability and durable metadata. Boundaries: untrusted media→parser/backend;
guest→agent→host; granted folders→guest; CLI/GUI→storage; subprocess→QMP;
downloads→updater; local user→VM lock/metadata. Treat every guest field as hostile.

| Threat | Planned/implemented mitigation | Residual gate |
|---|---|---|
| Malicious guest/image | Public framework isolation; no default integrations/network; bounded config parsing | Backend/driver escape risk; security review and fuzzing |
| Compromised agent/replay | Per-VM authenticated sessions, sequences, rate/size limits | Protocol not implemented; features hidden |
| Hostile shared file | Explicit grants, RO option, traversal/symlink policy, quarantine | Shared folder implementation and revocation tests |
| Local unsafe writer | Owned directory/private lifetime lock; reject FIFO/special files and hard-linked writable disk/EFI files; atomic metadata | Advisory lock bypass, ACLs and same-user replacement races remain |
| Interrupted/disk-full write | Preserve old metadata and guest disk, flush, recovery diagnostics | Power-loss campaign before durability/snapshot claim |
| Secret leak | Keychain; no source/media credentials; structured private logging; redacted export | Export boundary must pass fuzz/privacy tests |
| Input stuck/cursor lost | Focus/disconnect key release, visible capture recovery | Physical-key, IME, pointer/display test matrix |
| Compromised update | Verify signature/provenance; staged atomic rollback | Signing/updater not implemented |

Future untrusted-guest mode disables network, clipboard, drag/drop, folders and
host integrations. Default development experiment uses disconnected networking.
Justify every entitlement/helper. No privileged helper currently exists. Secrets,
OS media and local guest output must never enter public artifacts.


## Observed Windows-platform residual risks

The evaluated QEMU host-variable service writes JSON by in-place truncation,
write and fsync, and ignores the fsync result. Crash or power loss can invalidate
trust/variable state; successful ordinary shutdown cannot certify integrity.
Use fresh private stores for experiments, preserve failures, and require an
atomic/durable persistence strategy and fault tests before stable adoption.

Darwin cannot honor QEMU's MADV_DONTDUMP guest-memory exclusion. The firmware
experiment instead inherits a zero hard/soft RLIMIT_CORE, preventing ordinary
crash core files. This does not protect against privileged live-memory inspection.
Production process privacy and least-privilege isolation still require review.

A real PPI-on/HVF initialization abort exposed an unaligned-memory-listener
operation. The proposed source correction preserves the physical-presence
interface; firmware/TPM startup, Windows device health and full security behavior
must be verified afterward. A disabled interface or emulation fallback would not
satisfy the accepted Windows path. See the named-host mapping evidence.

## Experimental offline disk growth

Disk length and registration cannot change atomically together. Preserve exact
original/target configuration sidecars and publish a bounded pending plan before
extending the actual retained disk descriptor. Pending or invalid plans block
ordinary cooperating writers. Explicit completion validates the same directory,
disk inode, capacities and configuration bytes; its purpose-bound lease cannot
launch a runtime. A prior inherited lease prevents growth on that owner.

Treat all journal and sidecar fields as untrusted: reject escaped duplicate keys,
unknown schemas, unsafe aliases and reserved platform names. Preserve uncertain
states and never shrink, clear, or roll back automatically. Existing completed
archives may be reused only after exact private-file validation, without replacing
conflicting bytes. Free-space checks leave metadata headroom but cannot reserve
future guest allocation. These controls cover cooperating owners and observed
POSIX metadata; they do not exclude direct writes by the same user, establish ACL
policy, authenticate guest disk content or prove power-loss/filesystem recovery.
