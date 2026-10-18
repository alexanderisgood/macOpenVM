# Licenses and attribution for downstream source patches

This pack covers the **21 source diffs** in `Backends/Qemu/patches/`, as audited
on 18 October 2026. They are downstream modifications, not unmodified upstream
release files. The diffs identify the changes; the map records their targets,
upstream pins and exact patch hashes. The original application remains
Apache-2.0. File-specific upstream licenses and independently added helper
licenses are preserved; this pack does not relicense them under Apache-2.0.

This is source-only publication material, **not binary or runtime distribution
clearance**. It does not include QEMU, firmware, DXMT, renderer, Windows driver,
SDK or WDK binaries. Linking, corresponding complete source/build recipes,
LGPL relinking arrangements, security, signing and transitive binary obligations
remain separate release work. No unresolved-license exclusion was identified
for the retained patch snippets in this bounded source-notice audit; this is
not a legal or provenance clearance for the entire upstream source trees.

## Published source inventory

The patch map and separate components in `dependencies.json` describe these
source diffs. Personal developer loader paths use `/Users/developer` in this
public snapshot; the recorded patch hashes match those published bytes. No
upstream runtime binaries or retained private build trees are included.

## Upstream sources and important exceptions

- QEMU 11.1.0: exact `LICENSE` and GNU GPLv2 `COPYING` are copied. `LICENSE`
  explicitly assigns GPL-2.0-or-later to files without their own notice. Preserve
  each exception: CoreAudio and VNC are MIT; EGL helpers are LGPL-2.1-or-later;
  certain HVF/virtio headers say GPLv2-only; the standard virtio header carries
  a complete three-condition BSD notice; i386 HVF retains NetApp BSD and public
  domain attribution. An aggregate patch expression is not a claim that every
  line has every listed license or that QEMU as a whole is GPLv2-or-later.
- DXMT `66e27f3759ff79e41a791ec40e2a70ef6d0c964c`: current `LICENSE` and
  `COPYING.LIB` specify LGPL-2.1-or-later. `LICENSE.OLD` is copied solely to
  preserve historical MIT attribution, not to relicense current DXMT. The
  GUID helper retains DXVK zlib authors/notices and Alexander Bessonov's MIT
  parser attribution. Independently added timing helpers explicitly say
  Apache-2.0; their presence does not change the surrounding DXMT license.
- virglrenderer/Neptune `451505ad0aa449290f2c0672da6877d57ee770e5`: exact
  `COPYING` and the touched files' Chromium, Red Hat, Turing Software and Google
  notices are retained. The corresponding patch snippets are MIT.
- libepoxy `bf98587477fe68d07b93319ece7b40a7d0e2eabe`: exact `COPYING`
  preserves Intel MIT and the upstream Khronos notice. The loader patch's
  touched source retains Intel attribution.

`attributions/` contains exact source comment notices, including complete
per-file permission/disclaimer texts where present. `licenses/` contains exact
license-file bytes; `source-provenance.json` records their SHA-256 values and
retained source locations. Retained target files can contain local modifications;
this audit does not claim pristine upstream bytes or a reproducible binary.

## Patch map

| Source patch | Upstream | Conservative aggregate source licenses |
| --- | --- | --- |
| `auth2-strict-timestamp.patch` | qemu | `GPL-2.0-or-later` |
| `dxmt-completion-autorelease-pool.patch` | dxmt | `LGPL-2.1-or-later` |
| `dxmt-constant-interface-identifiers.patch` | dxmt | `LGPL-2.1-or-later AND MIT AND Zlib` |
| `dxmt-native-gpu-timing-evaluation.patch` | dxmt | `LGPL-2.1-or-later AND Apache-2.0` |
| `dxmt-pipeline-task-autorelease-pool.patch` | dxmt | `LGPL-2.1-or-later` |
| `fenced-blob-unmap-suspension.patch` | qemu | `GPL-2.0-only AND GPL-2.0-or-later` |
| `gpu-control-timing.patch` | qemu | `GPL-2.0-only AND GPL-2.0-or-later` |
| `metal-damage-readback.patch` | qemu | `GPL-2.0-or-later` |
| `metal-readback-swizzle.patch` | qemu | `GPL-2.0-or-later` |
| `neptune-metal-headless-qemu-11.1.patch` | qemu | `GPL-2.0-only AND GPL-2.0-or-later AND BSD-2-Clause AND BSD-3-Clause AND LGPL-2.1-or-later` |
| `neptune-native-loader-evaluation.patch` | epoxy, renderer | `MIT` |
| `qemu-coreaudio-actual-capacity.patch` | qemu | `MIT` |
| `qemu-coreaudio-format-topology.patch` | qemu | `MIT` |
| `qemu-coreaudio-nonmixing-admission.patch` | qemu | `MIT` |
| `qemu-coreaudio-playback.patch` | qemu | `MIT` |
| `qemu-coreaudio-realtime-lock.patch` | qemu | `MIT` |
| `qemu-coreaudio-signal-stats.patch` | qemu | `MIT` |
| `qemu-coreaudio-stream-start.patch` | qemu | `MIT` |
| `renderer-shm-scanout-cache.patch` | renderer | `MIT` |
| `shared-host-frame-display.patch` | qemu | `GPL-2.0-or-later AND MIT` |
| `vnc-active-refresh-16ms.patch` | qemu | `MIT` |
