# ADR 20: local structured support reports

Status: experimental implementation.

Users need a reviewable report when creation, setup or a VM operation fails.
Start with existing read-only inspection classifications and public numeric host
facts. Construct a versioned JSON report from typed fields and whitelisted roles
and finding codes. Exclude raw configuration, paths, names, IDs, addresses, guest
content, logs and exception text. Unknown capability facts remain unknown.

Export only after a user chooses a new local file. Use exclusive creation, private
permissions and durable file/directory writes; never replace an existing file or
VM metadata. No upload or network operation occurs. The report does not prove a
healthy backend, stopped guest, disk consistency or filesystem integrity.

Acceptance: readable bounded JSON, planted strings excluded, unknown fields
reported safely, real export roundtrip and source/existing-target preservation,
signed CLI use and native save-panel qualification. Optional logs require a
separate deliberate collection/redaction design and remain open.
