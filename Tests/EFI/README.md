# Original open EFI platform probe

This Apache-2.0 application reads SetupMode/SecureBoot, discovers the public TCG2
protocol, checks the active SHA-256 bank and requests one public TPM2 property.
It does not enroll keys, write variables, create NV data, clear/reset TPM state,
exit boot services or assert Windows compatibility. Missing/malformed observations
fail rather than producing a success marker. A SetupMode=1/SecureBoot=0 result is
an initial observation, not the provisioned secure platform required by ADR 6.

The probe uses documented UEFI/TCG definitions from the pinned EDK2 source. Build
with the private evaluated cross toolchain, add this directory to PACKAGES_PATH,
and select MacOpenVMLabPkg/MacOpenVMLab.dsc. Do not mount untrusted OS media on
the host or select an existing VM/system disk for experiments. Guest execution,
signed child verification, authenticated variable updates/runtime protection,
PCR/event-log replay and TPM NV persistence remain separate acceptance tests.

The original initial probe completed under native HVF after the reviewed GIC
feature-advertisement correction. It observed SetupMode=1/SecureBoot=0, TCG2
presence, an active SHA-256 bank and the public TPM manufacturer response. The
firmware/provider and probe build recipes, exact sources, artifacts and private
fixture results are recorded in the firmware evidence (private development record omitted).
Separate tests subsequently verified a completed TPM NV marker across orderly
restart and a scoped process crash, legitimate public-test PK representations,
and positive PK/KEK/db readbacks plus execution of our own signed EFI image.
These narrow results do not verify authentication rejection, runtime policy,
measured-boot consistency, TPM identity/power loss or Windows health/install/display.
EFI/Linux results cannot prove Windows TPM health.

Tests/Integration/windows_efi_probe.py requires explicit --run, a private platform
directory and pinned artifacts. Each invocation creates a new diskless fixture
with no networking and preserves its variable/TPM state. --diagnose-boot-timer
captures two bounded QMP/HMP processor snapshots during the first countdown, with
half a second of running time between them. Processor synchronization can perturb
execution; this mode always fails acceptance and marks diagnosticOnly=true.
It neither removes the countdown nor changes firmware timer/security policy.

TpmNvProbe supplies separate prepare/verify variants. Its only input is readonly
\MVO-NV-NONCE.TXT containing32 lowercase ASCII hex bytes and EOF. Verify excludes
NV mutation code during compilation. Tests/Integration/tpm_nv_persistence.py
requires explicit --run/platform/candidate arguments and always creates a new
empty owned store. It holds its writer lock across both boots; --crash-after-prepare
deliberately SIGKILLs only that new diskless test pair after verified preparation.
It never accepts an existing user VM/store. See narrow NV evidence (private development record omitted)
for actual results and the distinction from Windows, identity and power-loss proof.

PkEnrollmentProbe and PositiveTrustChainProbe are separate disposable positive
tests. The latter validates bounded public-test AUTH2 inputs and certificate ESL,
enrolls PK/KEK/db in a fresh store, and loads/starts our own signed original child.
The explicitly selected harness profiles pin all inputs and attach no private
key or OS disk. See positive interoperability (private development record omitted)
and positive chain execution (private development record omitted).
The published test identity cannot be used for production guest trust.

DisplayInputProbe uses bounded GOP mode/readback and a fixed repeated-digit USB
test. The explicit --display-input-probe harness profile creates a fresh offline,
diskless fixture, attaches one RAMFB/xHCI/USB keyboard, and disables serial input.
Two actual PPM captures must agree with guest dimensions and36 color samples per
stage, and every digit requires an actual guest acknowledgement. See the
first real run and limits (private development record omitted).
This is not a Windows desktop, native presentation, Retina or pointer test.

MeasurementConsistencyProbe and --measurement-consistency-probe retrieve only a
bounded main log and public PCR values in a new pinned no-OS fixture. The captured
decoder source is executed directly and its independent SHA-256 accumulation must
match both stable actual PCR snapshots. No final-event-table concatenation or TPM
mutation occurs. See the first native result and bounds (private development record omitted);
consistency alone cannot establish measurement authenticity or Windows TPM health.
