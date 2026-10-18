# 37. Recoverable whole-VM relocation to system Trash

Status: experimental implementation in qualification. Supported deletion must
use a real backend operation; removing a recent-library entry does not delete
VM files.

Add an explicitly confirmed Move to Trash action for dedicated `.macopenvm`
folders. Preparation validates the selected registration and expected UUID,
private folder/metadata/lock identities, ancestry, settled inactive runtime
history and disk-growth admission. It acquires an existing-only exclusive writer
lock and reserves that owner against runtime launch, configuration changes and
inheritance. Missing locks are refused without creating one. The prepared ticket
retains custody through confirmation; cancellation releases only its descriptors.
No VM is stopped, repaired or adopted by this operation.

A registration with both runtime intent and history absent is admissible under
the acquired existing lock. Missing records do not prove it was never run or its
filesystem is clean. A runtime record must match settled ownership and an inactive
terminal outcome; a forced
stop or failed outcome does not establish guest filesystem cleanliness. Move is
not filesystem repair. Unsettled, active, malformed, foreign or changed records
must refuse before relocation.

After confirmation, coordinate `.forMoving` using the documented
`NSFileCoordinator` and call `FileManager.trashItem` once. Keep the pinned source,
writer, source-parent and Trash-parent descriptors. Inspect the Trash leaf using
no-follow metadata and a bounded deny-only ACL snapshot; it is never opened or
listed. Revalidate within the coordinated accessor and verify the actual returned
destination's directory/writer identity,
metadata and source-name disappearance. A returned move is distinguishable from
not-moved and relocation-unverified. Cancellation after entering the native
operation may observe a committed move; no rollback is promised. There is no
permanent removal, manual `.Trashes` path, fallback copy, cleanup or retry.

Apple's historical Trash-specific release notes and the current generic directory
lookup documentation differ on `appropriateFor`. Do not infer volume support
from either alone: independently require source and resolved Trash on the same
device and validate the actual returned destination. External volumes and other
VM folder names remain requirements to qualify, not removed goals.
[Apple Trash API notes](https://developer.apple.com/library/archive/releasenotes/Foundation/RN-FoundationOlderNotes/index.html),
[directory lookup](https://developer.apple.com/documentation/Foundation/FileManager/url(for:in:appropriateFor:create:)).

Foundation accepts a path rather than an inode-conditioned relocation. Anchored
checks refuse prior replacements and detect post-move mismatches; they cannot
exclude a hostile same-user rename in the final check-to-call interval. State this
residual limit instead of claiming an atomic adversarial guarantee. A partial or
uncertain native outcome preserves records and an available reported location;
it never claims that all files stayed unchanged merely from an error.

The library dismisses before confirmation on the same VM-owning window. The
confirmation names the actual VM/folder and says its entire folder, including
disks, snapshots and platform/TPM state, moves to recoverable Trash. Cancel is the
default. Busy, creation and conflicting modal states refuse admission. After an
exact confirmed move, remove only the matching URL/UUID library entry and clear
only a matching inactive selection. A preference-write failure or uncertain move
remains actionable without automatic retry. Other files outside the VM folder are
not included in the relocation.

Acceptance: real private filesystem fixtures for lease/cancel/identity/stale
metadata, missing lock, symlink/ACL/permissions, coordinated revalidation, native
failure/uncertainty and relocation preservation; core history/identity tests;
UI confirmation/dismissal/context/late-state tests; strict build and independent
review; actual system Trash move and restoration of a new original empty test
VM with no existing VM or account data. A private injected destination is a test
seam only and cannot be selected by the product or CLI.

Native investigation showed that opening the whole system Trash directory is
unnecessary and denied in this environment, while its no-follow ACL/identity
metadata is readable. The corrected admission pins its accessible parent and
uses `fstatat(...AT_SYMLINK_NOFOLLOW)`, `lstat` and `acl_get_link_np` on the exact
leaf. Identity/ACL sampling is bound by before/after metadata checks and repeated
around native invocation. No permission grant or directory-enumeration fallback
is used. Metadata access failure still refuses. This enlarges the documented
same-user path race to the ACL sampling interval; it does not create an atomic
inode-conditioned API.

Source-parent compatibility is being extended to the same bounded restrictive
ACL policy, with exact parent ACL bytes pinned through confirmation and native
relocation. This addresses ordinary Documents/home delete-protection rules.
An allow ACE, malformed/unknown permission or flag, changed ACL (even another
deny-only ACL), or replaced parent still refuses. VM-folder, metadata and writer
checks remain private and no-ACL; no user's permission is rewritten. Private
fixtures and a new original blank native fixture qualify this change separately
from the earlier restored test.
