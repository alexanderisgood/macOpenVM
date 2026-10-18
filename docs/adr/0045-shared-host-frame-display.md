# 45. Evaluate a shared host-frame Metal display

Status: implementation experiment; live adoption requires measurement.

Native Windows delivery remains approximately51–54 callbacks/s. The actual
completion probe records short command-buffer GPU spans, while Raw display
delivery still copies, transfers and converts a full native frame. The signed
driver's public mode builder independently fixes its refresh timing at60Hz.
The target remains120 FPS at the native viewport; neither constraint is solved
by changing a label or repeating a previously displayed frame.

Before the direct guest-GPU export of ADR43 is ready, evaluate a narrower host
snapshot path. Keep the existing completed CPU readback and guest present/error
policies. Copy that host-owned snapshot into two dedicated, immediately unlinked
POSIX shared-memory objects. Send read-only descriptors through a separate private
Unix connection. Metal can wrap the consumer's page-aligned read-only mapping
with the documented bytes-no-copy buffer API and a linear texture. A generated
probe on this host passes both import and exact GPU-read checks. This is not
guest resource sharing, GPU passthrough or an elimination of the producer readback.

Use the existing owned runtime directory and a separate recorded endpoint bound
to its current VM/session. Validate the unchanged readiness bytes, parent/socket
identity, peer UID, descriptor type/access/size/link state, complete geometry and
strict numeric80-byte protocol before mapping. No global service, persistent
shared-memory name, guest pixel file, arbitrary file descriptor or texture from
guest memory is admitted. Ordinary VM configurations cannot select this trial.

One request and one frame may be in flight. Publish only a newer completed host
snapshot; static content must not inflate FPS. A frame carries connection epoch,
strict sequence, source generation, slot, geometry and bounded timing metadata.
Reuse requires the exact ACK after consumer GPU completion. Before ACK, copy the
shared texture into a private GPU cache, so later redraws never access a slot the
producer may reuse. All commits use one queue and retain mapped resources through
completion. Timeout/cancellation/peer death abandons the connection and retires
the pool; it cannot authorize early reuse or free a consumer's live GPU mapping.

Keep the working RFB route for initial framebuffer/input and fallback. A shared
frame must match the currently observed RFB geometry before activation. Resize,
stale session, malformed protocol, unsupported Metal or transport failure returns
to a fresh ordinary display connection, preserving capture preference and held-key
release. Persistent or malformed failures disable the shared path for that session.
The source54 candidate also recovers transient surface resets at any runtime age:
three retries back off250ms/1s/3s on ordinary RFB updates, and only120
completed cache copies and ACKs replenish the budget. This retains the same
input epoch while boot, unlock or game graphics surfaces settle. Source54
live recovery qualification remains pending; the current source52 trial still
uses the earlier boot-only recovery policy.
Menus, native fullscreen, aspect ratio, cursor rules and the owning window stay
on the same native guest view.

Acceptance requires native/4K every-pixel and opaque-alpha checks; read-only mapping,
fragmented metadata, unexpected/truncated descriptors, replay/stale ACK, resize,
consumer stall/exit, cancellation and descriptor/mapping lifetime checks. Generated
component timings separate CPU snapshot copy, control delivery and consumer GPU
completion. Then compare repeated live native delivery, Start/input/fullscreen and
normal shutdown with the fallback. Record all trials and limitations. No120Hz,
physical scanout, gaming or clear speedup claim precedes those results. Signed
driver work remains a separate requirement; signature enforcement stays enabled.

Public references: [Metal bytes-no-copy buffers](https://developer.apple.com/documentation/metal/mtldevice/makebuffer(bytesnocopy:length:options:deallocator:)),
[linear buffer textures](https://developer.apple.com/documentation/metal/mtlbuffer/maketexture(descriptor:offset:bytesperrow:)).
