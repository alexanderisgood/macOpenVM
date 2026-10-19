# Development storage

Preserve users' existing VM data. Keep development storage bounded:

- Reuse one build cache and one current artifact directory. Do not archive whole build trees or test bundles after each iteration; retain small logs, hashes and receipts instead.
- Do not make a new VM rollback copy for every code or UI change. Reuse a recent verified copy when suitable. For a change that needs a new copy, use an APFS clone of a confirmed stopped VM under its existing ownership checks, then verify the copy before retiring an older agent-created rollback.
- Keep at most one current agent-created rollback per actively maintained VM. Never delete an unrelated VM, a user's backup or the only copy of data as automatic cleanup.
- Remove disposable test disks, temporary source copies and obsolete compiler intermediates after their owners have exited. Preserve small qualification results needed to reproduce findings.
- Treat `.lab` as mixed storage: it can contain the actual user VM and pinned runtime binaries. Never delete it wholesale or assume every lab disk is disposable.
- Measure actual available bytes before and after cleanup. APFS clones share extents, so summed `du` or file allocation counts are not a physical-space savings claim.
- Raw disk creation must remain sparse. Guest discard may reclaim free clusters only through the normal block-device path; do not edit guest filesystem allocation maps or overwrite a live disk to compact it.

