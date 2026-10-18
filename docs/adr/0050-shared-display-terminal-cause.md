# Preserve a shared display's terminal failure during consumer completion

Status: experimental; App67 startup and game transitions pass without manual
reconnect. An intentionally forced instance of the exact ACK race is unverified.

Windows startup on App66 fell back from the Metal shared display with
`unexpectedMessage`. Manual View → Reconnect Display recovered Metal delivery
in the same VM. This observation alone does not identify which protocol guard
failed.

Inspection found a reproducible cause-loss race. The producer retires a surface
by closing its connection. The consumer can already own a frame and be awaiting
its actual GPU copy completion. Its socket reader observes ECONNRESET and clears
the outstanding token. The later acknowledge then reports unexpectedMessage,
hiding the reset and bypassing the existing bounded reset recovery. An independent
peer reproduces exactly that ordering: before the fix, ACK reports unexpectedMessage
and a later read reports closed instead of the original reset.

Retain the first terminal error on the existing serial transport queue. Subsequent
ACK/read operations on the closed connection report that cause; later cancellation
cannot replace it. An ACK is still sent only after actual GPU copy completion, and
no ACK is sent on a closed connection. Existing identity, geometry, sequence, slot,
descriptor and message checks remain strict. An unsolicited second frame retains
its fatal protocol error rather than being reclassified as a transient reset.

The focused shared-client and bounded-recovery suites pass. They cover EOF while
a frame remains borrowed, malformed traffic at the same boundary, original-cause
preservation through cleanup, retained read-only mappings and the existing retry
budget. A pre-existing long test comment was reformatted; strict formatting passes.
The first failed regression also had an incorrect generated-pool byte expectation;
the fixture starts at zero, and that assertion was corrected separately.

App67 passes release build, development signature and source provenance checks.
It was installed after App66's Windows worker pair stopped normally, flushed
platform state, settled intent and the actual app parent reaped with exit0.
QEMU34, signed guest drivers and graphics libraries are unchanged. The observed
startup fallback is a plausible instance of this reproduced race, not a proven
identity between the field failure and the regression. Acceptance requires live
startup/surface transitions retaining or recovering Metal delivery, with input
still usable and no manual reconnect. Neither 120Hz nor long-term stability is
established by this change.

Live App67 starts the preserved24GiB/12vCPU/120GiB Windows VM and reaches native
3456×2168 CS2 without manual reconnect. The20-second menu run reports60.4 Metal
completed draws/s, gap16.73ms median/21.45ms p95/36.95ms worst. A local DustII run
with bots reports56.7/s, gap15.84/29.94/130.65ms. Input Captured and Game Mouse
remain checked afterward, and native fullscreen reports the macOS menu visible.
A standard Windows graphics-reset chord was sent before loading the map, but its
underlying reset occurrence was not independently confirmed. Do not call that an
injected ACK-race proof. Normal guest settlement and actual app-parent reap both
finish with exit0. No driver or graphics-library bytes changed in this comparison.
