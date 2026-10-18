# Drain temporary Metal objects after each completed command chunk

Status: experimental in App69. Native ABI/import and Windows rendering checks
pass; memory and FPS benefit remain unqualified.

The native DXMT renderer's encoding path creates a scoped autorelease pool in
`CommitChunkInternal`. Its long-lived D3D11 completion thread has no equivalent
pool around Metal status, completion, log and readback calls. Cocoa temporary
objects on a secondary thread need a thread-local pool; a pool per iteration
bounds their lifetime. This follows Apple's
[autorelease-pool guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/Articles/mmAutoreleasePools.html).

Create the existing `WMT::MakeAutoreleasePool()` RAII value after the completion
thread's stop check, before examining the command chunk. Release it at the end
of that iteration, after command completion, readback/reset, fence publication
and allocator retirement. Those operations keep their existing ordering and
ownership. The wrapper's existing `Reference<Object>` releases the pool when its
scope ends. Objects that must survive are held by existing strong references.

The observed approximately19 GiB renderer footprint does not by itself prove an
autorelease leak. This change provides missing lifetime management; the amount
of recoverable memory and its effect on hitches/FPS require actual Windows
measurements. It neither limits texture/pipeline caches nor changes guest fences,
driver errors, guest refresh rates or frame capture.

Preserve the prior constant-identifier library, build/sign the candidate from an
inventoried source tree, and compare exported names and import closure. Admit it
only while the VM and actual app parent are settled. Qualify Windows startup,
native-resolution CS2 rendering, numeric display-delivery gaps, graphics-process
memory and normal shutdown. Retain rollback bytes. Do not infer120 Hz support,
perfect stability or a memory/FPS gain from compilation or driver naming.

The native rebuild and actual build/sign/verification parents exit0. All16
exported names and imports match the prior constant-identifier library; the
complete modified-source inventory and immutable prior bytes are retained.
App69's actual graphics closure, release/signing and source-provenance checks
pass. Windows starts and CS2 renders at3456×2168 without manual reconnect. The
native Mac menu is visible in actual native fullscreen.

A20-second CS2 menu run reports56.8 received/drawn frames/s, gaps17.95ms median,
22.89ms p95 and34.69ms worst; receive-to-draw is1.16ms median/5.74ms p95. The
preceding App68 menu was55.5/s with a78.07ms worst gap, but this sequential run
also changes QEMU/audio and does not control cache, scene or thermal conditions.
No gain is attributed to the pool. Separate host drawable-acquisition logs still
contain approximately483ms waits outside the measured interval. Memory growth,
gameplay hitches, long-term stability and120Hz remain open. Normal Windows/TPM
settlement and actual app-parent reap exit0; no app instance is left running.
