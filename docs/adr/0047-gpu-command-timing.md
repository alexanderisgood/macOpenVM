# 47. Bounded graphics control-queue timing

Status: diagnostic candidate, not a performance fix.

Native CS2 still has roughly10-second delivery gaps with1GiB and4GiB host
windows. Windows also records0x119/subtype1 scheduler crashes. The reviewed
signed-driver source contains10-second synchronous graphics-control waits.
Neither a missing host response nor a lost guest wakeup has been established.

Add numeric timing to the existing private Neptune QEMU profile. Stamp each
command once on its first dispatch. Record command-arrival gaps of at least100ms,
responses taking at least50ms, and the oldest pending fence after250ms. Record
the latest reply age/duration, command type/sequence/context/ring/fence and
existing inflight/blocked counts. These are transport IDs, not Windows scheduler
fence IDs. No payload, pixels, pointers, resource contents or guest text is read.

All sites execute under the existing QEMU main-loop/BQL ownership. Use GLib's
monotonic microsecond clock. Retain at most256 timing records plus one explicit
exhaustion marker per device lifetime. The existing poll examines only its first
pending fence; it does not add a timer, queue walk or completion wait. Ordinary
profiles remain uninstrumented. The diagnostic replaces the old128-command
startup-only log, leaving response/interrupt/fence order and error policy intact.

Build and freeze QEMU33 separately with its complete GPL corresponding patch,
unchanged renderer libraries and reviewed loader pins. Only a normally stopped
session may select it. The real Windows run must establish whether a10-second
gap coincides with a late response, an outstanding fence or a quiet submission
interval after an already-issued reply. Timing from this instrumented run is
diagnostic; any eventual speed claim needs the ordinary uninstrumented build.

The source patch remains GPL-2.0-or-later with QEMU; the independent Swift host
remains Apache-2.0. This local experiment does not clear redistribution/signing
or resolve the signed Windows driver's60Hz limit.

The first32 attempt is excluded: command extension fields were not initialized
by virtqueue_pop's g_malloc allocation.33 initializes only the diagnostic fields
at actual control-queue admission. An actual-header check starts those fields
poisoned and verifies initialization plus preserved command metadata, thresholds
and budget. The actual33 source builds/signs, and59 packages it after58's normal
guestStopped/settled shutdown, native Quit and actual parent reap.
