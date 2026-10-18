// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

/// Code-reviewed development inputs only. This is an explicit external-resource
/// profile, not a distributable library closure or Windows compatibility claim.
/// Approved catalog review SHA af8a8c62b510d077c74a571cff84c34ed2450460b42a168df92c122bc5545982.
public enum QemuRegisteredCatalog {
  /// Save-only permission after real verification of the independently reviewed
  /// shared runtime. No endpoints, runtime permit, device or network is created.
  public static func sharedNetworkConfigurationPermission(
    for configuration: VMConfiguration, projectRoot: URL
  ) throws -> SharedNetworkConfigurationPermission {
    guard configuration.guest == .windows11, configuration.backend == .qemuHVF,
      configuration.architecture == .arm64, configuration.boot == .efi
    else { throw registeredQemuFailure() }
    var projected = configuration
    projected.network = .shared
    try ConfigurationValidator.validate(projected, host: .current)
    let resources = try registeredEvaluation(for: projected, projectRoot: projectRoot)
    guard resources.supportsShared else { throw registeredQemuFailure() }
    try resources.verify()
    return SharedNetworkConfigurationPermission(configuration: configuration)
  }

  /// Desired fields select only independently code-reviewed descriptors. This
  /// performs no launch, signature/health qualification or networking consent.
  public static func registeredEvaluation(
    for configuration: VMConfiguration, projectRoot: URL
  ) throws -> ReviewedQemuLaunchResources {
    guard configuration.guest == .windows11, configuration.backend == .qemuHVF,
      configuration.architecture == .arm64, configuration.boot == .efi
    else { throw registeredQemuFailure() }
    let selected: ReviewedQemuLaunchResources
    switch configuration.network {
    case .disconnected: selected = try offlineEvaluation(projectRoot: projectRoot)
    case .shared: selected = try sharedEvaluation(projectRoot: projectRoot)
    }
    guard let path = configuration.supportMedia else { return selected }
    let carrier = try networkDriverSupportImage(projectRoot: projectRoot)
    guard path == carrier.url.path else { throw registeredQemuFailure() }
    return try ReviewedQemuLaunchResources(
      creation: selected.creation,
      libraries: selected.libraries, qemuImports: selected.qemuImports,
      swtpmImports: selected.swtpmImports, systemImports: selected.systemImports,
      runtimeQemu: selected.runtimeQemu, supportsShared: selected.supportsShared,
      supportImage: carrier)
  }

  /// Separately built display experiment. Ordinary launch selection never uses it.
  /// Same reviewed loader tree and host-loopback block; only active VNC cadence changes.
  public static func twoDimensionalDisplayEvaluation(
    for configuration: VMConfiguration, projectRoot: URL
  ) throws -> ReviewedQemuLaunchResources {
    var base = configuration
    base.supportMedia = nil
    let selected = try registeredEvaluation(for: base, projectRoot: projectRoot)
    let support: ReviewedQemuSupportImage?
    if let path = configuration.supportMedia {
      let carriers = try [
        displayDriverSupportImage(projectRoot: projectRoot),
        legacyDisplayDriverSupportImage(projectRoot: projectRoot),
        networkDriverSupportImage(projectRoot: projectRoot),
      ]
      guard let carrier = carriers.first(where: { $0.url.path == path }) else {
        throw registeredQemuFailure()
      }
      support = carrier
    } else {
      support = nil
    }
    let loader = try sharedEvaluation(projectRoot: projectRoot)
    return try ReviewedQemuLaunchResources(
      creation: selected.creation, libraries: loader.libraries,
      qemuImports: loader.qemuImports, swtpmImports: loader.swtpmImports,
      systemImports: loader.systemImports,
      runtimeQemu: ReviewedQemuResource(
        role: .qemu,
        url: URL(
          fileURLWithPath: projectRoot.path
            + "/.lab/qemu-display-cadence-d6551cb95d9345de981bf817e10d35d0/qemu-system-aarch64"),
        byteCount: 26_746_208,
        sha256: "14d090541541ea7a7026591366ab163bc0c0bb8454c88ce6307e3cabcadddd5a"),
      supportsShared: selected.supportsShared, supportImage: support)
  }

  /// Complete pinned 2D driver carrier; no guest installation or health permission.
  public static func displayDriverSupportImage(projectRoot: URL) throws -> ReviewedQemuSupportImage
  {
    guard QemuCreationLocalPath.isValid(projectRoot, maximumBytes: 4096) else {
      throw registeredQemuFailure()
    }
    return try ReviewedQemuSupportImage(
      url: URL(
        fileURLWithPath: projectRoot.path
          + "/.lab/windows-driver-support-74576ef0ea6441bf92f92d78cd62ec28/macopenvm-driver-evaluation-complete.iso"
      ),
      byteCount: 921_600, sha256: "cb9f8dea1c9c0647e73f61ecb204f3f09af2b9bfe46fe1056806b278878c8f6d"
    )
  }

  /// Exact prior display carrier retained for VMs that already reference it.
  public static func legacyDisplayDriverSupportImage(projectRoot: URL) throws
    -> ReviewedQemuSupportImage
  {
    guard QemuCreationLocalPath.isValid(projectRoot, maximumBytes: 4096) else {
      throw registeredQemuFailure()
    }
    return try ReviewedQemuSupportImage(
      url: URL(
        fileURLWithPath: projectRoot.path
          + "/.lab/windows-display-support-3ff9bac089d546578527603a56909818/macopenvm-display-evaluation.iso"
      ),
      byteCount: 921_600, sha256: "55897e3e181068a5e5e4ea52a1e2aed7ec2bbc296ae0afc549d0c139e2dbef3d"
    )
  }

  /// The exact public driver-only carrier. This does not grant installation,
  /// autorun, agent/enrollment, Windows driver-health or networking authority.
  public static func networkDriverSupportImage(projectRoot: URL) throws -> ReviewedQemuSupportImage
  {
    guard QemuCreationLocalPath.isValid(projectRoot, maximumBytes: 4096) else {
      throw registeredQemuFailure()
    }
    return try ReviewedQemuSupportImage(
      url: URL(
        fileURLWithPath: projectRoot.path
          + "/.lab/windows-network-support-aeb3fb95ab7d42f3b0ef8437b6edbb09/macopenvm-driver-evaluation.iso"
      ),
      byteCount: 921_600,
      sha256: "7c510ac451f1a692571eb8df408ddde36afd86ddff88281d366a2fc887ef2394")
  }

  /// Separately reviewed runtime capability. Creation provenance remains the offline profile.
  /// This grants no VM launch, networking consent, Windows or redistribution approval.
  public static func sharedEvaluation(projectRoot: URL) throws -> ReviewedQemuLaunchResources {
    let offline = try offlineEvaluation(projectRoot: projectRoot)
    let candidate = projectRoot.path + "/.lab/qemu-slirp-candidate-50c20db5653a47dd8a73d36439f45e66"
    let slirp = candidate + "/private-libslirp/lib/libslirp.0.dylib"
    let library = ReviewedQemuLibrary(
      url: URL(fileURLWithPath: slirp), byteCount: 156_992,
      sha256: "10d404d8a693f2d37401ce0ff54e71d9ffb4a5fe42335a360dea39e6d083a5ab",
      importPaths: [slirp],
      dependencies: [
        "/opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib",
        "/usr/lib/libresolv.9.dylib", "/usr/lib/libSystem.B.dylib",
      ])
    return try ReviewedQemuLaunchResources(
      creation: offline.creation,
      libraries: offline.libraries + [library],
      qemuImports: [
        "/System/Library/Frameworks/Hypervisor.framework/Versions/A/Hypervisor",
        "/opt/homebrew/opt/gnutls/lib/libgnutls.30.dylib",
        "/opt/homebrew/opt/pixman/lib/libpixman-1.0.dylib", "/usr/lib/libz.1.dylib", slirp,
        "/opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib",
        "/opt/homebrew/opt/dtc/lib/libfdt.1.dylib",
        "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
        "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", "/usr/lib/libSystem.B.dylib",
      ], swtpmImports: offline.swtpmImports, systemImports: offline.systemImports,
      runtimeQemu: ReviewedQemuResource(
        role: .qemu,
        url: URL(fileURLWithPath: candidate + "/qemu-system-aarch64"), byteCount: 26_746_208,
        sha256: "e2e40cce3cd0b394bb45190ec759bd33c7882bf65e186f4cdf2b5c4d9a7a3745"),
      supportsShared: true)
  }

  public static func offlineEvaluation(projectRoot: URL) throws -> ReviewedQemuLaunchResources {
    guard QemuCreationLocalPath.isValid(projectRoot, maximumBytes: 4096) else {
      throw registeredQemuFailure()
    }
    let candidate =
      projectRoot.path
      + "/.lab/windows-platform-a77101301bb14ba085a3a6e4b4f070ab/tools/qemu-vnc-candidate-1b9f04f265434bd08993c175502f5b89"
    let creation = try ReviewedQemuCreationResources(resources: [
      ReviewedQemuResource(
        role: .qemu, url: URL(fileURLWithPath: candidate + "/qemu-system-aarch64"),
        byteCount: 26_832_496,
        sha256: "26674b130d910136b31c7c576277639e8b4c5bc2bc499165acb8f39919e58529"),
      ReviewedQemuResource(
        role: .swtpm, url: URL(fileURLWithPath: "/opt/homebrew/Cellar/swtpm/0.10.2/bin/swtpm"),
        byteCount: 72192, sha256: "538a2dbbadcf907fb3910aa69e11b7c80d333950731809ade67129eda80c9a7a"
      ),
      ReviewedQemuResource(
        role: .firmware,
        url: URL(
          fileURLWithPath: projectRoot.path
            + "/.lab/windows-efi-probe-20261007T172609Z-b871dda885f443e68fe3f97458dbcc43/firmware-code-64m.fd"
        ), byteCount: 67_108_864,
        sha256: "28bc28488baa2d77f3bdd5e9187dbcc8d9c1a7eb809545340b5f7348a9a39532"),
      ReviewedQemuResource(
        role: .enUsKeymap, url: URL(fileURLWithPath: candidate + "/source/pc-bios/keymaps/en-us"),
        byteCount: 27086, sha256: "52cf4c523e686078699ed58761c7e1443080305237a5f67a3716832570c5c8e5"
      ),
    ])
    let libraries = [
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/gnutls/3.8.13_2/lib/libgnutls.30.dylib"),
        byteCount: 2_338_368,
        sha256: "20aab8f12c487059f8805ffe6c830d44b7c32c6e2b66e01014b6c51550868770",
        importPaths: ["/opt/homebrew/opt/gnutls/lib/libgnutls.30.dylib"],
        dependencies: [
          "/System/Library/Frameworks/Security.framework/Versions/A/Security",
          "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
          "/usr/lib/libz.1.dylib", "/opt/homebrew/opt/gettext/lib/libintl.8.dylib",
          "/opt/homebrew/opt/p11-kit/lib/libp11-kit.0.dylib",
          "/opt/homebrew/opt/libidn2/lib/libidn2.0.dylib",
          "/opt/homebrew/opt/libunistring/lib/libunistring.5.dylib", "/usr/lib/libSystem.B.dylib",
          "/opt/homebrew/opt/libtasn1/lib/libtasn1.6.dylib",
          "/opt/homebrew/opt/nettle/lib/libhogweed.7.dylib",
          "/opt/homebrew/opt/nettle/lib/libnettle.9.dylib",
          "/opt/homebrew/opt/gmp/lib/libgmp.10.dylib",
          "/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices",
        ]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/pixman/0.46.4/lib/libpixman-1.0.dylib"),
        byteCount: 615520,
        sha256: "a72debaf354c1bb7da04496217821364655276921f7d3980efcdcd699021b936",
        importPaths: ["/opt/homebrew/opt/pixman/lib/libpixman-1.0.dylib"],
        dependencies: ["/usr/lib/libSystem.B.dylib"]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/dtc/1.8.1/lib/libfdt.1.dylib"),
        byteCount: 56464,
        sha256: "0cc649c873e0c480f634540afcd5e37de983c3a0c5c087713e947e8bffa2659e",
        importPaths: ["/opt/homebrew/opt/dtc/lib/libfdt.1.dylib"],
        dependencies: ["/usr/lib/libSystem.B.dylib"]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/glib/2.88.3/lib/libglib-2.0.0.dylib"),
        byteCount: 1_359_280,
        sha256: "629b656720b26f44814cc1dbb34864f724f36e35f1909a2d008e9a435b7086e5",
        importPaths: [
          "/opt/homebrew/Cellar/glib/2.88.3/lib/libglib-2.0.0.dylib",
          "/opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib",
        ],
        dependencies: [
          "/usr/lib/libiconv.2.dylib", "/opt/homebrew/opt/gettext/lib/libintl.8.dylib",
          "/usr/lib/libSystem.B.dylib", "/opt/homebrew/opt/pcre2/lib/libpcre2-8.0.dylib",
          "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
          "/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices",
          "/usr/lib/libobjc.A.dylib",
        ]),
      ReviewedQemuLibrary(
        url: URL(
          fileURLWithPath: "/opt/homebrew/Cellar/swtpm/0.10.2/lib/swtpm/libswtpm_libtpms.0.dylib"),
        byteCount: 139440,
        sha256: "516f3f28367540aa652cffa9a76d2117834089553727213e195c0014f244170b",
        importPaths: ["/opt/homebrew/Cellar/swtpm/0.10.2/lib/swtpm/libswtpm_libtpms.0.dylib"],
        dependencies: [
          "/opt/homebrew/opt/libtpms/lib/libtpms.0.dylib",
          "/opt/homebrew/opt/json-glib/lib/libjson-glib-1.0.0.dylib",
          "/opt/homebrew/opt/glib/lib/libgio-2.0.0.dylib",
          "/opt/homebrew/opt/glib/lib/libgobject-2.0.0.dylib",
          "/opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib",
          "/opt/homebrew/opt/gettext/lib/libintl.8.dylib",
          "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib", "/usr/lib/libSystem.B.dylib",
        ]),
      ReviewedQemuLibrary(
        url: URL(
          fileURLWithPath: "/opt/homebrew/Cellar/json-glib/1.10.8/lib/libjson-glib-1.0.0.dylib"),
        byteCount: 191344,
        sha256: "0f05d8d31d21d7b13a535bf1054232ba08d56304baaf026cb2310091fe5afd8a",
        importPaths: ["/opt/homebrew/opt/json-glib/lib/libjson-glib-1.0.0.dylib"],
        dependencies: [
          "/opt/homebrew/opt/glib/lib/libgio-2.0.0.dylib",
          "/opt/homebrew/opt/glib/lib/libgobject-2.0.0.dylib",
          "/opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib", "/usr/lib/libSystem.B.dylib",
        ]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/glib/2.88.3/lib/libgio-2.0.0.dylib"),
        byteCount: 2_017_856,
        sha256: "4349f1b8c374046a20a5fa386009870bf0102719dfa7bd0397f4f19cb89c07e9",
        importPaths: ["/opt/homebrew/opt/glib/lib/libgio-2.0.0.dylib"],
        dependencies: [
          "/opt/homebrew/Cellar/glib/2.88.3/lib/libglib-2.0.0.dylib",
          "/opt/homebrew/Cellar/glib/2.88.3/lib/libgobject-2.0.0.dylib",
          "/opt/homebrew/Cellar/glib/2.88.3/lib/libgmodule-2.0.0.dylib", "/usr/lib/libz.1.dylib",
          "/opt/homebrew/opt/gettext/lib/libintl.8.dylib",
          "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
          "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
          "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
          "/usr/lib/libresolv.9.dylib", "/usr/lib/libSystem.B.dylib",
          "/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices",
          "/usr/lib/libobjc.A.dylib",
        ]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/glib/2.88.3/lib/libgobject-2.0.0.dylib"),
        byteCount: 398704,
        sha256: "bbd811feb8c56b19dcddf2ace04737d934e6d49730ec30fc71420aa6e1935c8a",
        importPaths: [
          "/opt/homebrew/Cellar/glib/2.88.3/lib/libgobject-2.0.0.dylib",
          "/opt/homebrew/opt/glib/lib/libgobject-2.0.0.dylib",
        ],
        dependencies: [
          "/opt/homebrew/Cellar/glib/2.88.3/lib/libglib-2.0.0.dylib", "/usr/lib/libffi.dylib",
          "/usr/lib/libSystem.B.dylib",
        ]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/openssl@3/3.6.4/lib/libcrypto.3.dylib"),
        byteCount: 4_872_736,
        sha256: "bae675614cd791d37ec35416ea9f87edcc85407d020810504cf458119b63522c",
        importPaths: ["/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib"],
        dependencies: ["/usr/lib/libSystem.B.dylib"]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/gettext/1.0/lib/libintl.8.dylib"),
        byteCount: 212080,
        sha256: "c84dabdb4ece983eded000a677040666c8496cd55c07db9816bf4a3eb216da58",
        importPaths: ["/opt/homebrew/opt/gettext/lib/libintl.8.dylib"],
        dependencies: [
          "/usr/lib/libiconv.2.dylib",
          "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
          "/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices",
          "/usr/lib/libSystem.B.dylib",
        ]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/libtpms/0.10.2/lib/libtpms.0.dylib"),
        byteCount: 943696,
        sha256: "86dd65e185443e5d2b68f79551117309b216c088344a96069c1cbdb2f73474d6",
        importPaths: ["/opt/homebrew/opt/libtpms/lib/libtpms.0.dylib"],
        dependencies: [
          "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib", "/usr/lib/libSystem.B.dylib",
        ]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/p11-kit/0.26.5/lib/libp11-kit.0.dylib"),
        byteCount: 1_602_832,
        sha256: "d482e5c96278dedd653287d1fe8d456657c8566cdd9d7822d31f2b35e60a0309",
        importPaths: ["/opt/homebrew/opt/p11-kit/lib/libp11-kit.0.dylib"],
        dependencies: ["/usr/lib/libffi.dylib", "/usr/lib/libSystem.B.dylib"]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/libidn2/2.3.8/lib/libidn2.0.dylib"),
        byteCount: 240256,
        sha256: "b62de17148cd0d635ce690fa8e3a641c9f0ef97f00da591dd9b51f3cbdf048f5",
        importPaths: ["/opt/homebrew/opt/libidn2/lib/libidn2.0.dylib"],
        dependencies: [
          "/opt/homebrew/opt/libunistring/lib/libunistring.5.dylib",
          "/opt/homebrew/opt/gettext/lib/libintl.8.dylib",
          "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
          "/usr/lib/libSystem.B.dylib",
        ]),
      ReviewedQemuLibrary(
        url: URL(
          fileURLWithPath: "/opt/homebrew/Cellar/libunistring/1.4.2/lib/libunistring.5.dylib"),
        byteCount: 2_016_752,
        sha256: "ea90c715c014787362941d35a2f2af168520bf11c2d07c592911fb361af20f9e",
        importPaths: ["/opt/homebrew/opt/libunistring/lib/libunistring.5.dylib"],
        dependencies: [
          "/usr/lib/libiconv.2.dylib",
          "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
          "/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices",
          "/usr/lib/libSystem.B.dylib",
        ]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/libtasn1/4.21.0/lib/libtasn1.6.dylib"),
        byteCount: 90192,
        sha256: "842043943eea48f94d7e33561b4451b9ac027491900aae39099df712e2cb3653",
        importPaths: ["/opt/homebrew/opt/libtasn1/lib/libtasn1.6.dylib"],
        dependencies: ["/usr/lib/libSystem.B.dylib"]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/nettle/4.0/lib/libhogweed.7.0.dylib"),
        byteCount: 279136,
        sha256: "87470a654b0e4bca27fd7e5bad7ca4d80afa1c7b16df68080ea2aa2d951a4509",
        importPaths: ["/opt/homebrew/opt/nettle/lib/libhogweed.7.dylib"],
        dependencies: [
          "/opt/homebrew/Cellar/nettle/4.0/lib/libnettle.9.dylib",
          "/opt/homebrew/opt/gmp/lib/libgmp.10.dylib", "/usr/lib/libSystem.B.dylib",
        ]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/nettle/4.0/lib/libnettle.9.0.dylib"),
        byteCount: 316432,
        sha256: "7ff68f13e9b15aee00ced345fd78f2547d8aa2a9059c6735bba51d10c0c82a0f",
        importPaths: [
          "/opt/homebrew/Cellar/nettle/4.0/lib/libnettle.9.dylib",
          "/opt/homebrew/opt/nettle/lib/libnettle.9.dylib",
        ], dependencies: ["/usr/lib/libSystem.B.dylib"]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/gmp/6.3.0/lib/libgmp.10.dylib"),
        byteCount: 436880,
        sha256: "8e5e329ef23a12e39885bbdf417f87654e163078916d904c5909d2224305e0cc",
        importPaths: ["/opt/homebrew/opt/gmp/lib/libgmp.10.dylib"],
        dependencies: ["/usr/lib/libSystem.B.dylib"]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/pcre2/10.47_1/lib/libpcre2-8.0.dylib"),
        byteCount: 573504,
        sha256: "dd80a92332fc1135e2dc86e4a3a1f5039f3416983d29b28942ca40807d3ad484",
        importPaths: ["/opt/homebrew/opt/pcre2/lib/libpcre2-8.0.dylib"],
        dependencies: ["/usr/lib/libSystem.B.dylib"]),
      ReviewedQemuLibrary(
        url: URL(fileURLWithPath: "/opt/homebrew/Cellar/glib/2.88.3/lib/libgmodule-2.0.0.dylib"),
        byteCount: 53600,
        sha256: "50e52e83851fda109d7865cf8496573c1a22b7db16b52bc0c4c012fa5541e365",
        importPaths: ["/opt/homebrew/Cellar/glib/2.88.3/lib/libgmodule-2.0.0.dylib"],
        dependencies: [
          "/opt/homebrew/Cellar/glib/2.88.3/lib/libglib-2.0.0.dylib", "/usr/lib/libSystem.B.dylib",
        ]),
    ]
    return try ReviewedQemuLaunchResources(
      creation: creation, libraries: libraries,
      qemuImports: [
        "/System/Library/Frameworks/Hypervisor.framework/Versions/A/Hypervisor",
        "/opt/homebrew/opt/gnutls/lib/libgnutls.30.dylib",
        "/opt/homebrew/opt/pixman/lib/libpixman-1.0.dylib", "/usr/lib/libz.1.dylib",
        "/opt/homebrew/opt/dtc/lib/libfdt.1.dylib",
        "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
        "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", "/usr/lib/libSystem.B.dylib",
        "/opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib",
      ],
      swtpmImports: [
        "/opt/homebrew/Cellar/swtpm/0.10.2/lib/swtpm/libswtpm_libtpms.0.dylib",
        "/opt/homebrew/opt/json-glib/lib/libjson-glib-1.0.0.dylib",
        "/opt/homebrew/opt/glib/lib/libgio-2.0.0.dylib",
        "/opt/homebrew/opt/glib/lib/libgobject-2.0.0.dylib",
        "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib",
        "/opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib",
        "/opt/homebrew/opt/gettext/lib/libintl.8.dylib",
        "/opt/homebrew/opt/libtpms/lib/libtpms.0.dylib", "/usr/lib/libSystem.B.dylib",
      ],
      systemImports: Set([
        "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
        "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices",
        "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
        "/System/Library/Frameworks/Hypervisor.framework/Versions/A/Hypervisor",
        "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
        "/System/Library/Frameworks/Security.framework/Versions/A/Security",
        "/usr/lib/libSystem.B.dylib", "/usr/lib/libffi.dylib", "/usr/lib/libiconv.2.dylib",
        "/usr/lib/libobjc.A.dylib", "/usr/lib/libresolv.9.dylib", "/usr/lib/libz.1.dylib",
      ]))
  }
}
