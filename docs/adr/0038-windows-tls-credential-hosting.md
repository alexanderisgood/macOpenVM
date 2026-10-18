# 38. Prove Windows TLS credential hosting before agent service integration

Status: experimental prerequisite. Two deterministic ARM64 handshake-only static builds (private development record omitted)
pass. The native fixed-record extension also builds twice identically (private development record omitted);
Windows TLS signing, authentication and records remain unverified.

The existing original virtio-serial transfer evaluator proves only fixed public
byte progress when executed. A Windows agent must act as the TLS server for the
host's existing TLS client, then use generated Hello/Health messages. Before a
service is implemented, prove that its chosen credential can actually sign the
TLS 1.3 server handshake under documented Schannel APIs.

A temporary PFX import with `PKCS12_NO_PERSIST_KEY` attaches a pointer-backed
`CERT_KEY_CONTEXT_PROP_ID`. Microsoft documents that this key context cannot be
marshalled to another process such as LSASS. Acquiring a Schannel credential is
therefore insufficient proof of usable signing, and its unused key callback is
not a supported shortcut. Do not silently persist keys or install a root trust
anchor to make a handshake pass.

The next executable spike should pump bounded SSPI client/server tokens in one
process using a fresh private lab identity, without a driver, network socket,
service, root-store changes or real user credentials. It must drive an actual
TLS 1.3 handshake far enough to perform certificate signing, query the negotiated
version and observe native completion before cleanup. A rejected credential or
handshake changes the credential-hosting choice; it is not worked around by
reducing authentication or protocol versions. A later scoped CNG persistence
strategy needs separate explicit enrollment/custody and uninstall proof.

For the future server, requiring a client certificate does not validate it.
Schannel server acceptance must be followed by a scoped Crypt32 chain engine
restricted to the enrolled roots, clientAuth purpose, chain-policy result and
exact enrolled leaf before any agent message. Client certificate DNS validation
must not be inferred from the SSL policy callback's client-auth mode. Either
explicitly validate a bounded SAN name using the public decoder, or define client
identity by exact leaf and VM enrollment without a DNS-name claim. Revocation,
expiry, clock and policy results remain explicit; no system-root-store fallback.

The transport still needs bounded fragmented token handling, incomplete-message
and extra-byte processing, TLS record encryption/decryption, cancellation and
actual descriptor/operation settlement. A codec, credential acquisition, open
socket or port flags alone cannot establish authenticated guest health.

Acceptance for the credential-hosting spike: strict deterministic ARM64 static
build, named native import closure, exact no-key-persistence/root-store mutation
scope, actual Windows execution with TLS1.3 certificate signing or a recorded
native refusal, negotiated context/peer assertions and terminal handle cleanup.
Only then connect to the separately qualified vioser route and generated schema.

Primary-source review supports these gates:
[PFX no-persistence and LSASS limitation](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-pfximportcertstore),
[Schannel credential acquisition](https://learn.microsoft.com/en-us/windows/win32/secauthn/acquirecredentialshandle--schannel),
[modern credential parameters](https://learn.microsoft.com/en-us/windows/win32/api/schannel/ns-schannel-sch_credentials),
[TLS protocol parameters](https://learn.microsoft.com/en-us/windows/win32/api/schannel/ns-schannel-tls_parameters),
[server-side client validation](https://learn.microsoft.com/en-us/windows/win32/secauthn/performing-authentication-using-schannel),
[exclusive chain engine](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/ns-wincrypt-cert_chain_engine_config),
[client policy name limitation](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/ns-wincrypt-httpspolicycallbackdata).

The bounded transport adapter must retain incomplete tokens and validate EXTRA
as the unconsumed input tail, send final output tokens before releasing buffers,
handle post-handshake/renegotiation statuses explicitly and verify final context
flags/version. TLS1.3 system-policy refusal stays a refusal; registry protections
are not changed. Scope can retain native Kernel32/Secur32/Crypt32 imports, adding
NCrypt only for explicit key-handle ownership. No socket/driver/service is needed
for the first in-process signing experiment. [Extra-buffer rules](https://learn.microsoft.com/en-us/windows/win32/secauthn/extra-buffers-returned-by-schannel),
[record decryption/post-handshake processing](https://learn.microsoft.com/en-us/windows/win32/secauthn/decryptmessage--schannel).

Before the native adapter, a small portable token-custody contract has passed
fifteen strict and sanitized fixture cases (private development record omitted): fixed-size input accumulation, bounded
step IDs, exact EXTRA-tail validation, no-progress refusal, final output-token
completion and cancellation ownership. It uses independent byte fixtures and
never performs SSPI, TLS, certificate import or authentication. Its tests cannot
be cited as native signing or peer proof; the actual adapter must supply native
context/peer evidence and perform the signing experiment.

## First native evaluator scope

The first original console evaluator is deliberately limited to certificate
hosting and an in-process handshake. It will use two separately supplied fresh
disposable lab PFX files with an empty password, a fixed private lab CA and
distinct server/client purposes and names. Its closed selector is an operator
assertion of that scope, not proof that arbitrary input files are fresh. No PFX
or private key belongs in source, static-build evidence or a generic support ISO.
No certificates have been created for this evaluator yet.

Each import must expose exactly one CNG-backed leaf key context and one lab
root, without a persisted provider reference. Modern server/client credentials
are acquired separately; protocol restrictions are mandatory. Scoped exclusive
root engines, validity/signature/purpose policy, exact peer DER and explicit
bounded SAN checks precede any successful result. Requested mutual-auth flags
alone do not count as peer validation.

Memory delivery owns copied opaque tokens before releasing provider allocations.
The client initial leg has no input and sits outside the read-first portable
contract. Native EXTRA counts are validated against the submitted input; the
owned tail is derived from that count. A final provider token still needs
delivery. TOKEN and ALERT allocations need cleanup on both success and refusal.

The initial evaluator can retain bounded opaque ciphertext delivered after a
peer's context completes, without processing it as a record or plaintext. It
will refuse incomplete credentials and statuses outside its handled set, and
report no TLS records or guest health. Such a refusal can expose a limit in the
evaluator rather than prove that Schannel credentials are unusable. Application record processing,
post-handshake handling and vioser integration remain separate acceptance gates.
Its step/time budgets are cooperative; synchronous Windows API calls are not
claimed to be interruptible. The static build never creates or opens lab keys,
executes its PE or modifies a VM.

The portable record prerequisite now passes fifteen strict/sanitized cases (private development record omitted) and is limited to one fixed public payload per
direction. Actual QueryStreamSizes observations bound the native header/data/
trailer allocations; actual EncryptMessage return must precede packing only the
produced spans. DecryptMessage completion needs bounded DATA and EXTRA observations
before matching the fixed payload. Incomplete ciphertext is retained for a later
fragment, empty successful output is control progress, and renegotiation preserves
the modified input while blocking further record calls until negotiation. These
fixtures will validate custody and spans, not perform cryptography or qualify a
general TLS application stream. Native record and post-handshake execution remain
required. [Encryption layout](https://learn.microsoft.com/en-us/windows/win32/secauthn/encryptmessage--schannel),
[decryption and post-handshake rules](https://learn.microsoft.com/en-us/windows/win32/secauthn/decryptmessage--schannel).

## Native fixed-record extension acceptance

After the credential evaluator's actual TLS1.3/scoped-peer gates, extend the same
in-process run to one encrypted fixed public record in each direction. Query
native stream sizes, supply the required header/data/trailer/empty encryption
buffers, and validate actual produced spans before delivery. The receiver must
process bounded retained ciphertext and empty control output, preserve incomplete
input and admit only its exact expected record. A renegotiation status must resume
the native negotiation with retained modified input and repeat context/peer
checks, or refuse explicitly before further record calls. It must never be
treated as successful application data.

Acceptance requires strict deterministic static ARM64 builds with the exact
EncryptMessage/DecryptMessage import additions, followed by actual Windows
execution with both records matched, native status and terminal cleanup evidence.
Static imports and fixtures remain prerequisites only. The previous handshake-only
build remains historical evidence with zero records; later source changes cannot
retroactively promote it. No schema health/service, driver, persistent enrollment
or generic support-media claim follows from two fixed records.
