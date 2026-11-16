# Guest Tools preview verification, 16 November 2026

Scope: the original ARM64 installer, matched basic/2D/accelerated tools media,
and the Mac preparation UI in ADR 65. This is development evidence, not a
supported binary release or a new graphics-performance measurement.

## Automated and build checks

- 1,339 Swift tests passed, with process-wide lease tests run separately.
- Seven tools-input tests passed, including altered archives, path traversal,
  case collisions, symlinks, corrupt ISO metadata and required GPU classification
  in both graphics package profiles.
- Swift formatting, protocol generation and SBOM checks passed; 33 benchmark
  harness tests passed. These are harness checks, not performance scores.
- The main Python integration group passed 332 tests (four explicit skips). It
  initially encountered four missing local
  legacy fixture files. Restoring only their exact manifest-pinned bytes from
  the verified driver archive made the 16 affected tests pass (four explicit
  prerequisite skips). Linux-agent integration coverage remains a separate CI
  group; no complete local `check.sh` pass is claimed here.
- Two builds produced identical tools ISO and executable hashes. All generated
  files were read back byte for byte. Final ISO hashes are in
  `packaging/guest-tools-pins.json`.
- Release app build, provenance check, bundled-image validation and strict ad-hoc
  signature verification passed. Eleven installed app files matched the build.

## Native Windows observations

The initial installer run exposed a real classification defect: Windows did not
enumerate the selected GPU, and the UI treated it as optional and declared the
matching drivers ready. After Windows returned through its sign-in screen, its
PCI enumeration showed the GPU with Code 28 (driver missing). The precise reason
for the earlier absence was not established.

Running the combined installer then installed the matching signed Neptune v0.4
package. Its UI reported network and accelerated graphics Working. Independent
PnPUtil readback showed the VirtIO GPU 3D controller Started. Independent registry
queries confirmed both `TdrDebugMode` and `EnablePreemption` were absent after the
operation, preserving their original defaults. Normal Windows shutdown completed.

The corrected installer makes a missing promised GPU an incomplete setup and
offers restart/retry guidance. An absent optional serial device is described as
not attached. The Mac UI exposes the firmware setup display and GPU display and
retains that choice on reconnect. The corrected build is installed locally.

## Remaining qualification

The first live transition to the GPU exposed stale/black incremental display
updates; reconnecting recovered a current frame. The first fresh-boot attempt blocked while opening the completed Windows
installation ISO before guest launch. Detaching that unused media through the
stopped VM UI allowed launch; the ISO file was preserved. Final guest retesting
is in progress. Missing-payload rejection is covered at the build/input level but still
needs the native executable negative-path check. Do not label this flow fully
qualified until those checks complete.

Windows publisher signing, complete upstream transitive notice review, clean
machine/accessibility testing and full runtime redistribution remain release
gates. The experimental HDR guest builds are not installed or bundled here.
