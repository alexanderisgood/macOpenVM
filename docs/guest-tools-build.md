# Building the optional Windows Guest Tools discs

The source build can run without bundled tools. A distributor can supply three
pinned, read-only discs under `build/guest-tools`; `scripts/build.sh` verifies and
copies them into the app before signing. Partial or modified bundles fail the
build. The discs contain drivers and an original native ARM64 installer, never
Windows installation media.

The recommended storage option uses Windows' own powercfg and retrim tools.
It disables guest hibernation and Fast Startup, verifies the hibernation file is
absent, and reports reclaim separately. Uncheck it to preserve the current
settings. Paging, recovery, updates and personal files are unchanged. It does
not enable compression or promise a fixed number of bytes saved. Hibernation
can be re-enabled with Windows' `powercfg /hibernate on` when needed.

The basic profile includes networking and VirtIO serial. The display profile adds
the signed 2D driver. The accelerated profile instead includes the unmodified
signed Neptune v0.4 package paired with macOpenVM's modified wire-2 graphics host.
The two graphics drivers are alternatives, not cumulative upgrades. Custom HDR
guest experiments are not in this bundle. The public source build still needs
the separately qualified Windows runtime described in the setup guide.

## Inputs and toolchain

Supply these files explicitly; the builder does not download dependencies:

- `macOpenVM-virtio-win-0.1.302-1-arm64.zip` from the
  [driver preview](https://github.com/alexanderisgood/macOpenVM/releases/tag/windows-arm64-virtio-0.1.302-1),
  SHA-256 `b054af39278900da9def6163f3b9b13e615b73b18b0fce33b47f6d89c76fa008`.
- `viogpu3d-arm64x-signed.zip` from
  [Neptune v0.4](https://github.com/osy/kvm-guest-drivers-windows/releases/tag/v0.4),
  SHA-256 `512da8ef87eaf4f65282e2535bf1dc2b32b0b0f825508093532fbb1ab0b09116`.
- LLVM clang and llvm-dlltool, LLD with the ARM64 PE linker, and a compatible
  llvm-mingw Windows header directory. Native qualification used LLVM/LLD 23.1.5
  on macOS; the exact generated pins are toolchain-dependent. Windows SDK import
  libraries and a Windows installation are not needed to build the installer.

```sh
python3 scripts/build-guest-tools.py \
  --virtio-zip /path/to/macOpenVM-virtio-win-0.1.302-1-arm64.zip \
  --neptune-zip /path/to/viogpu3d-arm64x-signed.zip \
  --llvm-bin /path/to/llvm/bin \
  --linker /path/to/lld \
  --headers /path/to/llvm-mingw/include
```

The builder rejects altered archives, unsafe names and symlinks, compiles the
installer with warnings as errors, pins every payload file in the executable,
and reads back every generated Joliet file byte for byte. Intermediates are
temporary; the three discs and a small manifest replace the current outputs.
Rebuild twice and compare manifest hashes before updating
`packaging/guest-tools-pins.json` and `QemuGuestToolsCatalog.swift` together.
Never accept a changed upstream archive merely by replacing its checksum.

## Verification and distribution status

Run `python3 -m unittest discover -s Tests/Integration -p test_guest_tools.py`,
the Swift guest-tools/media-admission tests, then the ordinary check and release
build. A native Windows test must additionally verify driver health, normal UAC,
missing-payload rejection and restoration of the graphics recovery settings.
Attaching the disc or successfully staging an INF does not prove driver health.

This installer is a preview and has no Windows publisher signature yet. Preserve
upstream notices and source references. The current accelerated disc has not
completed the full transitive notice review for its bundled user-mode graphics
libraries; do not publish that binary until that review is complete. Signing,
clean-machine, accessibility and complete runtime distribution gates also remain
required for a supported prebuilt app.
