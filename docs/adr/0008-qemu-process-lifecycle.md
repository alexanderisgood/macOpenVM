# ADR 8: own the QEMU runtime before exposing Windows launch

Status: implementation experiment. Windows launch and guest support remain gated.

The application has a backend-neutral controller but its QEMU component currently
produces only an argv plan. The verified native firmware tests use a separate
Python runner. Add an original Swift process/QMP adapter so the application core
can own and control a real QEMU runtime through the same lifecycle contract.

The adapter launches direct executable/argument arrays, never a shell. QMP uses
an owned private Unix socket, bounded JSON lines, explicit request IDs, version
handshake and monotonic deadlines. Blocking process/pipe/socket work must run off
the main actor. Continuously drain child output with bounded preservation; a
failed/full log must not block the child or silently drop active ownership.

QEMU and its TPM daemon form one lifetime. Launch completion requires actual QMP
running status; pause/resume require observed status. Neither establishes guest
readiness. Any live process or unfinished output drain keeps the adapter active
and its caller's writer lease retained. Failed/cancelled start cannot implicitly
force-stop an already launched guest. Unexpected daemon exit reports failure while
the surviving QEMU remains owned. Explicit force-stop may request QMP quit and,
if necessary, terminate only the registered owned children; completion requires
their actual terminal status and finished drains.

The first executable integration uses a newly prepared pinned no-OS fixture,
with no user disk or networking. It tests start, actual EFI output, pause/resume,
explicit force-stop, ownership release and failure paths through the Swift core.
No production Windows button or unsupported display setting is added. Windows
install/display/input, protected firmware/current trust/dbx, lawful media and
drivers remain separate requirements. Liquid Glass presentation is retained.

Acceptance:

- Real local process tests cover output flooding, EOF, failed spawn and cancelled
  waiting without automatic termination or leaked ownership.
- Local QMP peers cover fragmented/event-interleaved responses, bounds, rejection,
  deadlines, request identity and close behavior.
- The exact native candidate boots the original EFI probe under this Swift owner,
  pauses/resumes with actual QMP status, quits both children and preserves hashes.
- A partial launch or backend/control failure retains active ownership until
  explicit recovery and confirmed child/drain completion.
- Strict concurrency, project warnings-as-errors and existing core tests pass.

This is runtime implementation progress, not a substitute for the required Windows
workflow or the full parity objective. The private candidate's macOS27 floor and
unadopted dependency closure do not change the macOS14 product requirement.

Current VMLock descriptors close on exec. Retaining the Swift owner therefore
does not protect a persistent guest from a writer lease disappearing after an
external owner crash while QEMU survives. Gate this first launcher to brand-new
diskless fixtures. A guardian or verified child-held lease and reconnect/recovery
contract must precede production disk adoption; no crash-ownership claim follows
from normal shutdown tests.
