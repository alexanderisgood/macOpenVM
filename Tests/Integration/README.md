# Explicit native guest tests

`prepare_auth_variable_vectors.py --platform-directory ABS` prepares deterministic
AUTH2 inputs with published EDK2 test trust. `authenticated_variables_lab.py --run
--platform-directory ABS --qemu-record ABS --vectors-directory ABS --probe ABS`
runs eleven EFI replacement cases against the pinned baseline. Add
`--strict-time-candidate` for the separately pinned correction. Each run creates
a new private diskless offline fixture and retains stores/logs. Policy failures
return nonzero after owned QMP cleanup. The original build reproduces two
equal-timestamp failures; the corrected build passes. See the
evidence (private development record omitted)
for exact artifacts and open gates. Never substitute a personal VM or key.

## Original EFI image enforcement

`prepare_image_verification.py --platform-directory ABS --positive-fixture ABS`
prepares original unsigned, signed and altered EFI images, a second valid image
signed by the same published test certificate, and an authenticated SHA256 DBX
update. The positive fixture supplies the pinned PK/KEK/db enrollment vectors.
`image_verification_lab.py --run --platform-directory ABS --qemu-record ABS
--vectors-directory ABS --probe ABS` uses only the separately pinned timestamp
correction, a reviewed module build and input set, and a fresh diskless offline
fixture. It never substitutes a personal VM, key or OS image. Signing time can
change prepared image identities; review any new set before updating pins.

The retained native experiment completed nine cases and six original child
executions. Setup-mode controls executed both negative inputs. User-mode checks
rejected unsigned/altered images and the hash-revoked signed image; a different
image signed by the same certificate executed on both sides of revocation's
negative attempt. The first decoder incorrectly required SHA256 to be the sole
active TPM bank. Its failed result is preserved; the corrected decoder requires
the SHA256 bit and qualified the same terminal log in `evaluated-result.json`
without a new guest. Twelve decoder regression tests pass. See
exact evidence and hashes (private development record omitted).
This is one-boot original-EFI LoadImage/StartImage evidence; Microsoft trust,
Windows, cold-boot persistence and runtime policy remain unverified.

These tests are separate from unit checks. Use an Apple-silicon host with public
native virtualization support and the ad hoc signed development CLI. Prepare a
lawfully obtained ARM64 Alpine live image and raw kernel/initrd with the existing
media/preparation scripts. Create a new disposable `.lab/Alpine-nat.macopenvm`
using the CLI direct-kernel options and explicit `--network shared`; this directory
is test data, not an installed personal guest. Keep the saved configuration/media
private. No media is bundled or automatically downloaded by this test.

Run `python3 Tests/Integration/native_serial.py --run` only when the fixture is
stopped. It checks serial Ctrl-C, terminal restoration, stable MAC, DHCP/route/DNS,
verified outbound HTTPS and clean shutdown/lock release. It does not prove complete
N1/D4 or performance. Network requests use example.com without credentials.

Without --run, native entitlement/support or prepared media, the test reports an
explicit prerequisite reason. A failed check saves private evidence under a unique
.lab directory. A live guest is retained; the same test session forwards console
input for recovery. Establish the actual shell before sending a command. Do not
restart or force-stop a guest merely because a response times out.

`hardware_settings_native.py --run --build /absolute/private-build-directory`
uses a current source-matched, signed private build and the pinned local Alpine
kernel/initramfs/media to create a new offline VM. It observes 2 CPUs/2 GiB in the
guest, powers off, saves 3 CPUs/5 GiB through the public CLI and observes the new
resources on a second boot. It checks exact backup, identity, blank disk, input
preservation, guest exit and writer release. This is a RAM-root resource test,
not native settings-window, installed-filesystem or Windows qualification. It
does not touch existing VMs or download media; without `--run` it explicitly skips.

`python3 Tests/Integration/native_storage.py --run` uses the stopped offline
`.lab/Alpine-native.macopenvm` configuration only as a media template. It creates
a unique NEW VM, confirms its empty 2 GiB block device is unmounted, writes and
flushes a bounded 4 KiB marker at offset 1 MiB, and checks guest/host hashes across
three boots. It checks writer exclusion and release without changing the template.
Add `--crash-trial` to explicitly kill only this new disposable runner in cycle 2
after the marker has been durably flushed. The following boot must preserve it.
All new disks, identity and private logs remain in .lab; failures retain active
guests for console recovery. This is not installed-filesystem, snapshot or host
power-loss validation. Never substitute a personal disk or VM for this fixture.
