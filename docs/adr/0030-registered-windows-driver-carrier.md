# ADR 30: bounded read-only Windows driver carrier

Status: source and actual read-only image checks qualified; driver execution and health unqualified.

The registered Windows worker needs a driver carrier to qualify its virtio network
device. The existing support ISO is private evaluation data: NetKVM's four required
installation files, the separately staged vioser files, BSD notices and README.
It contains no autorun, macOpenVM agent, pairing material or credentials. It is not
the released combined setup disc required by the product specification.

Add a non-serialized, independently caller-reviewed support-image value to launch
resources. Its path, exact length and digest are checked with stable no-follow
regular-file identity and ownership before planning and during revalidation.
The optional value defaults to absent. A saved `supportMedia` path cannot authorize
a carrier: it must exactly match the independently reviewed image. An unselected
reviewed carrier adds no device. Metadata cannot provide arguments or trusted flags.

The plan adds one read-only USB support drive, separate from the system disk and
installation disc. It has no boot priority or host-side setup command. Preserve
VM/MAC identity, firmware/TPM state, compute, networking and existing disk arguments.
The old Linux QemuPlan remains unchanged. Existing media selection already passes
through VMLock's anchored runtime-intent and disk-growth admission; a suspected
missing check was disproved by source inspection and its existing regression test.

The independently inspected carrier is 921,600 bytes, SHA256
`7c510ac451f1a692571eb8df408ddde36afd86ddff88281d366a2fc887ef2394`,
with volume `MACOPENVM_TEST`. All ten file members match staging. NetKVM requires
SYS/INF/CAT and `netkvmp.exe`; a PDB is not an installation file. Retained offline
Microsoft signature/catalog/member checks are scoped evidence; revocation,
Windows driver policy/loading/health and per-file redistribution/source closure
remain unproven. A whole-image digest does not confer execution permission or
establish guest health.

Source acceptance checks exact one-drive/read-only/path escaping behavior,
unchanged installer/system/NAT/MAC/platform data, refusal without independent
binding, wrong hash/length/aliases/modes and revalidation drift. Actual filesystem
and writer tests must create no endpoint, runtime intent, process or network.
Next qualify actual carrier attachment and driver installation in a separately
authorized fresh VM, then real network and normal-shutdown/cold-boot checks.
Ordinary UI attach/shared Start and generic Run Setup remain gated until their
actual workflows exist and pass. The one-support-disc/one-setup-tool objective
remains required for production guest integration.


Root34363 passed49focused registrations, including actual carrier digest verification and existing unsettled-intent media admission. Core/Storage source stayed unchanged. Independent review accepted the bounded carrier and exact one-read-only-drive recipe. A test name was corrected to avoid equating absence of boot index with unbootability. Evidence (private development record omitted) remains source/image qualification only.

Normal CLI validation, worker admission and App preflight now share one closed code-catalog selector. Desired network/support fields choose reviewed descriptors; they cannot mint resource trust. Root82434 passed57 focused source/native-read-only checks. Offline creation and GUI shared-mode gating remain unchanged. Actual support selection on a fresh stopped normal VM is the next file-only acceptance step.
