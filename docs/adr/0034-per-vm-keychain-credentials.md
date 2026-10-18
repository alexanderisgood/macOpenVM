# 34. Per-VM credentials without authentication prompts

Status: experimental source implementation and injected tests; production pairing and signed
Keychain access remain unqualified.

The current TLS health transport consumes transient in-memory test credentials.
Daily guest integration needs per-VM credential custody without repeated Mac
password prompts, secret files in the project or unrelated VM boot failures.

Store a bounded private pairing record in a local, nonsynchronizable Data
Protection Keychain item, scoped to a fixed macOpenVM service and VM account UUID.
The record includes VM/enrollment identity, host certificate/private key and exact
approved peer CA/leaf/name trust. Add only if absent; duplicates preserve the
existing enrollment. Load validates schema, VM binding and bounds. No automatic
rotation, deletion, unlock, reset, legacy-Keychain or file fallback is provided.
Secret material is not publicly Codable and has redacted descriptions.

Use a noninteractive LAContext with the documented authentication-context query.
The Data Protection selector is required: the same no-UI guarantee does not apply
to legacy file-based Keychain items. Missing, denied, locked/interaction-required
or entitlement-unavailable results are explicit integration errors. The VM launch
path does not read this store and remains independent of pairing availability.

The TLS entry point loads only the requested VM's record. Existing bounds and
credential/trust DER validation run before connection creation; certificate
purpose, name, exact-leaf trust and TLS1.3 are checked during the handshake before
ready state or health messages. Stored data is not authentication or guest-health
evidence by itself. There is no insecure transport or trust fallback.

The Security framework boundary is injected and typed for error/query/VM-binding
tests. Initial tests must not mutate or enumerate the user's Keychain. A later
native probe may read only a fresh isolated service/account without interaction;
persistence, signing/access groups, locked/denied behavior and a real authenticated
guest exchange require their own evidence. The maintainer's namespace and signing
profile are still absent, so no release-level credential-access claim follows.

Acceptance: bounded private serialization, exact per-VM queries, add-if-absent,
duplicate preservation, missing/locked/denied/unavailable classification, no UI or
fallback/reset calls, no secret diagnostics, credential checks before connection
and full TLS validation before health messages, strict
build/tests, and native qualification appropriate to the actual signing context.

Root's focused run now passes eleven store/integration tests and four existing
TLS guards, including the real private Unix socket guard. No native Keychain
query or VM operation was executed. Evidence (private development record omitted).

The API choice follows Apple's [TN3137](https://developer.apple.com/documentation/Technotes/tn3137-on-mac-keychains)
and [authentication-context query](https://developer.apple.com/documentation/security/ksecuseauthenticationcontext),
also checked against the installed public Security and LocalAuthentication SDK
headers. The default service is a development identifier, not a release access
group. Data Protection Keychain authorization depends on the signed application's
provisioning and permitted groups; native custody remains unqualified.

Native qualification starts with an explicitly selected read-only lab command.
Two fresh nonzero UUIDs select only an isolated development test service and VM
account; they never select the ordinary store service or an existing VM. The
command calls the real store loader once, emits only a typed outcome and discards
any unexpectedly returned material. It cannot add, update, delete, enumerate,
export, reset, prompt, fall back or start a VM. Observing missing authorization
changes the next signing action; observing not-found proves only an isolated
lookup in the current application's authorized scope, never persistent custody.

The named ad hoc executable now completes the actual isolated no-UI read and
returns notFound. This qualifies the missing-item lookup on that host only;
persistence, release access and native locked/denied behavior remain open.

An explicit public-fixture roundtrip evaluator now selects only three distinct
fresh test UUIDs and a fixed marker. It can create a deliberately invalid-DER
public record after an exact missing lookup, compare readback internally, test
duplicate preservation and verify it from another launch of the same immutable
executable. It cannot accept supplied credentials, enroll a peer, reset/delete
items, prompt or fall back. A cancellation after an admitted add can leave the
public item; the caller preserves commit uncertainty rather than retrying.
Nine injected tests verify query order, collision refusal, typed failures,
material comparison and privacy. Native attempted add/second-launch retrieval
are separate evidence under the actual signing context. A public test item is
not an authenticated identity or release access-group qualification.

The actual public-fixture add now returns missingEntitlement in the existing ad hoc development context. Native qualification (private development record omitted) records the failed creation; no second-launch verification, retry, fallback or signing mutation followed. Authorized release Keychain access remains a distribution gate.
