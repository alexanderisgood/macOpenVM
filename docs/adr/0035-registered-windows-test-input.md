# 35. Explicit input for a current registered Windows test display

Status: experimental evaluator with bounded native navigation evidence.
This does not qualify the full desktop input workflow.

The ordinary Windows GUI owns its worker and refuses captured input when macOS
will not give its window focus. An explicitly authorized test connection can
operate the current VM through the existing public RFB client without changing
that GUI focus policy or reconstructing native ownership.

Expose a separate lab command for snapshot, one click or one named navigation
key. Require the exact registered VM/runtime/session and current healthy worker
status, held writer, canonical worker route and bounded closed display route.
Match both endpoints to the selected runtime generation and pin the display
socket identity. Input requires the SHA256 of a reviewed original framebuffer;
reject changed frames, session/revision changes, recovery, pending lifecycle,
unsafe coordinates and arbitrary keys/text. Release input and close only this
client on success or failure. Never retry automatically, signal a process,
stop/restart a guest, acquire its writer or mutate VM files.

Snapshot saves content only when explicitly requested to a new private PPM file.
The result contains bounded correlation and hashes; raw pixels never enter its
Codable output. Click/key calls retain no image or guest text. User credentials,
account submission, licence acceptance and security changes remain outside this
navigation evaluator's scope.

Acceptance: request/route/frame/revision/privacy tests, strict build and review;
current session status and exact visual frame inspection before one real input;
observed guest response and held-input release; no lifecycle or metadata changes.
The GUI's physical/synthesized keyboard, pointer, focus and full accessibility
matrix remain separate release gates.

The snapshot output parent is pinned before the capture await. Saving uses
exclusive `openat` relative to that descriptor; changed parents, symlinks,
existing files and extended ACLs are refused. Parent and output descriptors
require no extended ACL, with checks before any pixel write. A failed save can
leave a private partial file; no atomic-image guarantee is claimed.

Verification is recorded in bounded navigation evidence (private development record omitted).
A fresh explicit Next advanced the actual test guest beyond recovery into region
and keyboard selection. Immediate post-input frames sometimes precede the
asynchronous guest response; they never authorize automatic replay.

A separate read-only observation command consumes 1 to 120 incremental frames
on the same admitted connection. It returns only VM/session, epoch, dimensions,
count, elapsed time, completion and a closed phase label; it stores no pixels, guest text or frame hashes and
sends no input. Epoch/sequence/geometry and repeated live-route checks remain.
A 30-second pre-frame admission window and individual frame watchdogs bound
work; this is not a strict whole-command timeout. Quiet incremental displays
can time out without implying VM failure. Admission/privacy tests and actual
transport observation are distinct evidence.

An admitted observation that does not complete reports the number of validated
frames and the last fixed phase with `completed:false`; the CLI exits 2. This
phase is not a root-cause classification. Invalid pre-admission requests remain
errors, and cancellation closes the client and propagates cancellation. No
exception text or guest content is included in the observation result.
