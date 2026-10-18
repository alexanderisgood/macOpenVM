# ADR 19: stopped VM copies with independent disk writes

Status: implementation in progress; experimental Linux/AppleVz slice.

The full product needs clone/templates with independent writable state. While
the actual Windows installation waits for native foreground input, implement the
shared offline transaction without changing that installation or existing VMs.

Use an exclusive matching source owner and strict registration. A nonempty source
disk requires a valid recorded guest stop. When intent exists, it must be settled
and match the VM/session; pending, forced, failed and corrupt records fail. Current
AppleVz callers legitimately use directory-scoped history without intent. A newly
blank disk can be copied when both runtime records are absent. No free-lock-only
claim of clean shutdown is made.

Create a new destination exclusively and retain its own owner. Use descriptor-bound
APFS `fclonefileat` only, with distinct inode/single-link checks and conservative
ACL rejection. Filesystem copy-on-write extents may be physically shared until
changed; each VM has an independent writable file. There is no hardlink or fallback
that silently expands a sparse image. Unsupported/cross-volume operations fail
with a recovery suggestion. Check capacity with overflow-safe arithmetic.

Generate new VM/MAC and Apple platform identity; copy no source identity, EFI
variables, runtime history, locks or transaction sidecars. Keep external read-only
media references and reject references inside the source bundle. Networking starts
disconnected. Guest machine identifiers and account files remain part of the disk;
guest credential regeneration/pairing is a separate requirement. Windows/TPM and
encrypted-guest clone policy remain open. Fresh EFI variables require actual
installed-guest boot qualification before an EFI clone is advertised as supported.

Flush the copied disk and new platform identity before publishing configuration
last, using exclusive atomic publication. Recheck source registration/history/disk
identity; never overwrite an intervening destination registration. Failure preserves
the original and any unregistered partial destination, with no automatic rollback.

Acceptance: real sparse marker copy, distinct inodes, independent flushed writes
in both directions, strict source stop/admission, reserved names and unsafe aliases,
existing destination, stale records, interruption/identity/publication failure,
resource and capacity checks; then a fresh native installed-guest copy boot,
write, ordinary shutdown and original-disk preservation. Full Windows and template
acceptance stays on the feature matrix until separately verified.
