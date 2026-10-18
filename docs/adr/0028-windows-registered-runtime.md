# ADR 28: Windows creation and a registered worker/display session

Status: normal Windows CLI creation and validation verified; narrow native registered startup/reconnect/forced settlement and programmatic ordinary App selection/start/SDK rendering/forced settlement verified. Physical GUI, installation and clean Windows shutdown remain unqualified.

Windows 11 ARM64 remains the primary guest. The existing private worker has reached
Microsoft Setup and first-run setup, but the ordinary creation/library path is
Apple/Linux only. It must acquire real Windows creation, registered ownership and
Liquid Glass display behavior rather than expose an unsupported Start control.
Private fixture entry points and their consent/evidence rules remain separate.

First add a bounded platform-identity result to the shared creation contract:
`CreatedPlatformIdentity(files, emptyPrivateDirectories)`. The platform receives
the actual configuration when creating identity. Core validates unique safe direct
names, at most eight total, disjoint from disk/configuration/writer/runtime/growth
bookkeeping. It flushes every returned regular file and every empty private
subdirectory under the actual new-VM writer before committing configuration.json.
Apple returns the same existing identity and EFI files; no behavior changes there.

Storage needs an anchored no-follow empty-directory flush operation bound to the
actual VMLock: verify the selected VM directory, child owner, exact0700 mode,
empty namespace and stable child identity; flush child and VM parent, and report
failure before registration. Test aliases, nonempty directories, wrong writer,
permissions, duplicate/reserved identity names and failure preservation. This
primitive supplies durability, not a backend or guest-health claim.

Then implement QEMU creation from a caller-reviewed resource bundle. New private
EFI variables and qemu-platform.json bind normal configuration.id to exact reviewed
QEMU/swtpm/firmware/data-resource lengths and digests plus fixed VM-contained state
names. A fresh tpm-state directory is uninitialized; creation runs no QEMU/swtpm
process and generates no TPM-health, Secure Boot or supported-Windows assertion.
The resource record contains no argv, runtime sockets/session IDs, pairing material
or metadata-approved trust flag. Launch revalidates against the reviewed bundle,
host floor, signatures/entitlements and actual files.

Next the worker reads the admitted normal registration under its own VMLock and
uses that VM ID with RecordedRuntimeOwner. Both owned QEMU and swtpm children retain
the real lease. An injected validated VM/session route connects a worker-backed
desktop session to RFB; remove startup-flag/global-lab coupling for this path.
Closing or disconnecting a display preserves the worker and guest. Reconnect must
verify actual IPC identity; disk IDs/PIDs cannot reconstruct ownership. Existing
input, network, elevation and account consent stays explicit.

Actual child/drain termination precedes flushing bounded known TPM files, their
directory and EFI variables under the retained writer; platform flush uncertainty
retains custody before final recorded settlement. History/intent flushing alone
cannot establish this platform-state durability.

Acceptance progresses through a fresh offline reviewed Windows registration,
recorded worker, Liquid Glass display and detach/reconnect with owner retained.
Creating files, a bootloader, mocks or Setup alone do not close guided installation.
Installed media/compliance/driver health, NAT choice, account handoff, disc-detached
cold boot, normal Windows shutdown, recovery, minimum-host and release distribution
remain required gates. The existing live installation and pending NAT/account
choices are unchanged; no new launch or network authority follows from this ADR.

The first creation durability seam is implemented and source-tested. It adds the
bounded result/configuration binding, rejects reserved/case-fold name collisions,
and flushes actual owner0700 empty directories through the retained writer anchor.
Apple returns its previous identity files; Linux clone scope remains unchanged.
33 focused creation/clone/support-media/storage registrations pass, including
injected child/parent flush failures and actual named-directory replacement. This
qualifies the filesystem seam only. QEMU platform resource binding, fresh registered
Windows worker/display behavior and native guest acceptance remain next stages.


The current reviewed external QEMU profile has an actual macOS27 floor (swtpm26),
ARM64 executable and explicit resource pins. Its Homebrew library imports are not
a self-contained release dependency closure. Keep this experimental profile floor
explicit; the original macOS14 host objective remains required. QEMU hypervisor
entitlement, executable architecture/signature and reviewed loader checks are
launch obligations. A host application virtualization entitlement cannot replace
QEMU's required entitlement. The file-only creation API never supplies launch
authority or inferred device/guest health.

Account handoff requires the mutable test VM to live outside the source project.
The Windows fixture was originally beneath .lab; a guest account would write
credential/account state to that disk even if host input is never logged. Before
human account entry, use normal guest shutdown and actual parent/child termination,
full drains, settled same-session intent and an independent writer check. A separate
reviewed external continuation moves the entire stopped fixture by same-filesystem
rename into a new private user-data directory, preserving disk/EFI/TPM/writer/history
bytes and inodes. Archive old input/history unchanged; never symlink, adopt PIDs,
clone a new identity or move live files. The external launcher needs a fresh actual
writer permit and newly bound run/session/routes. Existing fixed-project validators
remain separate; the credential-storage constraint is not waived by a private or
ignored project folder.

This relocation has now completed before human account entry: the actual stopped
fixture moved by exclusive same-filesystem rename into private Application Support
storage. The subsequent E725 continuation retains the original VM identity and has
reached Sign in. Its live owner and display stay separate from ordinary registered
runtime qualification. No account or desktop-completion claim follows from that step.


The next vertical slice admits an ordinary registered offline Windows configuration.
A caller/code-reviewed, non-serializable launch resource bundle adds exact physical
library pins, loader alias mappings, signatures, ARM64/Mach-O and host-floor checks.
The saved platform record continues to provide provenance only. Admission requires
the actual configuration bytes and real VM writer, then recomputes fixed arguments
from that configuration and independently reviewed resources. QEMU key-value paths
are escaped; unsupported swtpm path separators refuse before launch. No environment,
argv, PID or permission is obtained from saved VM data.

The worker preflights its fresh private endpoints and VM-contained runtime record
folder before opening a recorded session. It acquires its own writer and inherited
child leases, exposes same-session status/control for partial startup recovery and
retains ownership until actual termination, drains, platform flush and durable intent
settlement. The generic Windows store flushes the configured disk, bounded variables
and allowed stopped TPM files through the retained settlement permit before committing
ownership. Empty or partial known TPM state after failed initialization establishes no
TPM health; unexpected namespace or flush failure preserves custody.

A typed registered display context injects normal VM identity, current owner session,
parent launch generation, readiness bytes/digest and endpoint identities into the
existing RFB renderer/input/fullscreen controller. The ordinary path accepts a separate
route scope; lab flags and fixed experimental identities remain separate. Reconnect
changes display/input only. Current selection and launch generation are rechecked across
suspension, while lifecycle actions use exact-session status and revision checks.
Windows Start and creation controls stay gated until the actual registered worker and
client lane pass native acceptance. Initial creation remains offline; new networking
choices remain explicit per VM. The existing human sign-in trial is preserved.

The ordinary CLI has now created a fresh offline Windows registration, validated it
and inspected it without starting a guest. A separate Liquid Glass Windows creation
assistant is being connected to this same file-only transaction. Native worker
qualification uses only the newly blank disposable registration, read-only display
observation and explicitly requested lifecycle controls. It accepts no OS licence,
installs no operating system and enters no account details.


The fresh registered native slice now passes offline startup, raw display detach/reconnect and explicit forced settlement with actual child exits/drains, platform flush, matching settled intent and independent writer availability. It remains experimental and verifies no visible GUI or clean guest shutdown. The App parent must supply actual private regular stdout/stderr files required by producer admission. Use a separate retained actual LeaseSpawn.Child in the App with regular standard-stream descriptors; preserve the proven pipe-based QEMU/TPM OwnedProcess. Foundation.Process was tested and its process-group behavior conflicts with the worker’s setsid boundary. Bundled helper admission verifies the outer app and fixed helper identifiers, exact sealed descriptor and actual bytes before any launch.


The App library integration is now source-qualified: exact bundled-worker admission, retained actual child, immutable registered display context, same-object lifecycle callbacks and display cleanup before releasing App busy state. Fourteen source/native-boundary and49regression registrations pass. The native worker itself passed the separate narrow offline startup/reconnect/forced-settlement trial. Actual App current-bundle startup, visible GUI, physical input and normal Windows shutdown remain separate gates.
