# Legal and distribution questions

This is an engineering risk register, not a legal clearance. Original implementation
is Apache-2.0. No proprietary sources, art, private resources or binaries were
inspected. No OS, product key, firmware or driver is redistributed by this source
slice. Local OS media and evaluation binaries stay outside release assets.

| Question | Current disposition / release gate |
|---|---|
| QEMU GPL and aggregation/linking | [QEMU license](https://www.qemu.org/docs/master/about/license.html) identifies GPL v2 and component-specific terms. Independent process is a boundary, not legal clearance. Review combined distribution, corresponding source, modifications, build scripts and notices before adoption/bundling. |
| EDK2 and embedded code | Installed notice has BSD-2-Clause-Patent, MIT, historical BSD, SoftFloat and OpenSSL/SSLeay notices. Pin firmware build and every embedded source/license; verify provenance, keys and redistribution before shipping. |
| swtpm/libtpms and drivers | Versions, source and full transitive licenses needed. ARM64 Windows driver signatures, installer and update rights unresolved. No third-party installer bundled. |
| OS licenses/media | Users lawfully obtain their own ARM64 OS and licenses. Anonymous Microsoft ARM64 transfers are retained privately but remain unaccepted because their selected English checksum associations failed; see media evidence (private development record omitted). Public download availability does not establish installation rights or redistribution permission. No account, license acceptance, product key or unattended acceptance was used. |
| Patents/graphics | GPU/codec/translation/peripheral patent questions need review; no assumed immunity from open-source license. |
| Apple entitlements | Virtualization entitlement documented in public SDK. Hypervisor for QEMU, bridged network and possible extensions/helpers must be individually justified and reviewed. |
| Signing/notarization | One development identity is available; no Developer ID/notarized release verified. Credentials may not reach PR jobs. |
| App Store | Sandbox, external subprocess/firmware/driver/update restrictions unresolved; no Store suitability claim. |
| Bundle namespace | local.macOpenVM is provisional. Maintainer must provide controlled namespace before distribution. |
| Security/pairing | [Experimental per-VM Data Protection store](adr/0034-per-vm-keychain-credentials.md) has injected tests only; native authorization requires a qualified signed/provisioned access group and controlled namespace. No legacy/file fallback, Keychain reset or repeated password boot workflow. Secrets never enter release discs/logs. |

dependencies.json records source URLs, versions, modifications, redistribution
obligations and scope. Generated SBOM marks incomplete evaluation inventory honestly;
a release needs complete transitive inventory, license review and reproducible builds.

The October GPU evaluation uses native LGPL DXMT, MIT Neptune/virglrenderer,
BSD ANGLE and a GPL QEMU source build, independently acquired from pinned public
repositories. D3DMetal and installed third-party app binaries are not used.
The signed guest package is privately inspected; corresponding Mesa UMD source,
per-file licenses, signing/revocation and complete redistribution obligations
remain open. GPU source and evidence (private development record omitted).

The Windows-directed firmware investigation distinguishes QEMU's existing generic
firmware recipe from a newer protected-variable candidate. Audit exact EDK2 gitlinks,
embedded cryptographic code, enrollment/revocation binaries, transitive notices,
build/signing provenance and host parser isolation before adoption. Compiler/device
availability or an enrollment success message is insufficient. Official Enterprise
evaluation media requires an account/registration path; that is a separate user
decision and is not used as an automatic workaround for missing installation rights.

Native Data Protection Keychain add qualification now returns missingEntitlement for the virtualization-only ad hoc development executable. Release access requires the maintainer’s authorized signing identity, bundle namespace, provisioning and permitted groups; no legacy store or password-prompt fallback is used. Exact native evidence (private development record omitted).
