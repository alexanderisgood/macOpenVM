# ADR 25: observed QEMU guest shutdown

Status: experimental source/contract implementation and native firmware poweroff (private development record omitted) qualified; Windows ACPI response remains unqualified. Source evidence (private development record omitted) records the exact executed inputs and limitations.

The current runtime discards QMP events and classifies every nonforced exit as opaque. A normal stop therefore needs event observation as well as a power request. Keep the backend's one owned QMP connection and strict parser. Send `system_powerdown` through that connection; its correlated reply acknowledges a request only. Do not create a second monitor, infer shutdown from status, or fall back to quit/signals on timeout.

An event-driven lifetime reader must route command replies and retain bounded typed shutdown provenance for its own connection epoch. The qualifying event is `SHUTDOWN` with exact `guest=true` and `reason=guest-shutdown`. `POWERDOWN`, `STOP`, reset/panic/host reasons, command ACKs and process exit0 alone do not qualify. Natural EOF and complete reader/descriptor settlement are distinct from cancellation or intentional close. Malformed input and control/output failures remain sticky.

Use one terminal predicate for both the backend callback and sealed receipt: qualifying current-connection guest event, naturally settled monitor, both actual owned children exited normally with status0, complete output drains/closed pipes, no survivor, no force and no prior failure. Parent writer ownership persists through durable history settlement. This proves observed guest poweroff, not guest filesystem quiescing or application flush correctness.

TPM and monitor callbacks can arrive in different orders. Only normal TPM exit0 can receive provisional assessment; nonzero/signalled/output failures remain immediate failures. Drain already-available frames on the same transport before deciding whether an existing shutdown witness covers expected TPM finalization. Absence of such evidence at that boundary remains a failure; a later event or reply cannot repair it. Ambiguous ordering stays unverified. Never establish causality from saved PIDs, wall timestamps or delayed callback order.

Keep the synchronous backend stop contract through a retained supervised asynchronous request operation. Pending request/monitor assessments participate in active and settlement gates. A request timeout or cancellation preserves every living child and its ownership. Existing forced termination and unknown-exit outcomes remain distinct.

Acceptance includes fragmented/interleaved replies/events, idle shutdown, final event before EOF, intentional-close/cancel distinction, ACK/status-only rejection, wrong/malformed reasons, child/event/TPM ordering, prior failure preservation, incomplete drains/survivors and blocked history commits. Native socket/process contract fixtures establish these mechanics; a fresh approved Windows trial must establish real ACPI behavior before support claims.

Current live Windows and Ubuntu owners use immutable prior executables. This source work does not alter them or supply permission for guest shutdown, networking or credential entry.
