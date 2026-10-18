# 48. Preserve suspended fenced graphics cleanup

Status: experimental; fixed queue regression and first live Windows/CS2 comparisons pass narrowly.

The corrected33 trace during real Windows/CS2 records resource-unmap replies
at10019–10022ms, with other replies continuing and the oldest unmap fence pending.
The signed driver's synchronous unmap waits10seconds. Inspection establishes
that virgl's unmap handler can suspend for RCU memory-region release and return
before creating a renderer fence. Generic command processing interprets the
guest's FENCE bit as proof the command was not suspended, moves it to fenceq,
and never resumes its remaining cleanup/fence creation. An unrelated later
global fence can then retire it. This is a concrete host queue defect; its
exact share of every observed freeze or0x119 crash remains unverified.

Adapt Akihiko Odaki's public GPL patch6/9, **Fix fenced blob unmapping**, posted
8 September2026 and reviewed by Marc-André Lureau. The existing private runtime
already includes7/9's separate inflight-count correction, but lacks6/9.
Source: https://patchew.org/QEMU/20260908-gpu-v3-0-25332a85f909@rsg.ci.i.u-tokyo.ac.jp/ .

Track suspension independently in the command object. Clear it immediately
before dispatch; unmap/unref write it directly. Leave a suspended command at
the head of cmdq regardless of FENCE, then resume its cleanup after RCU release.
Only after cleanup completes create and await its actual fence. Keep the
existing resource lifetime, renderer-blocked gate, callbacks and guest driver.
Do not complete commands early, invent a fence or shorten Windows' timeout.

Verify the actual old/new queue functions with a delayed cleanup/fence fixture:
the old version must reproduce premature queue movement, and the fixed version
must preserve head/order, avoid early completion and resume cleanup once. Build
and freeze QEMU34 with author/source/license records. After normal shutdown,
use the same Windows native viewport/4GiB window and CS2 menu scene. Acceptance
requires absence of the recurring10-second unmap waits and delivery gaps, then
offline gameplay and longer scheduler stability checks.120Hz remains separate.


Live App60/QEMU34 at3456×2168 measured58.3 received/drawn frames/s in the
CS2 main menu, versus6.8/s in the preceding App59/QEMU33 menu run. Draw-gap
median17.12ms, p9521.54ms and worst41.48ms; receipt-to-draw median1.03ms.
The first offline DustII deathmatch sample measured55.7/s, median16.00ms,
p9530.44ms and worst404.18ms. This is a stationary-camera run before the
relative-input fix. The earlier recurring10-second waits have not reappeared
in these samples. Short, sequential, uncontrolled trials do not prove a
universal speedup,120Hz, internal game resolution, physical scanout, absence
of shorter hitches or long-term scheduler stability. Keep those exits open.
