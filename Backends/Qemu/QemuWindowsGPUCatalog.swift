// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

extension QemuRegisteredCatalog {
  /// Private, source-built graphics evaluation. Stored configuration never selects it.
  /// QEMU preserves virt-11.1, UEFI variables and TPM; no commercial graphics libraries.
  public static func acceleratedDisplayEvaluation(
    for configuration: VMConfiguration, projectRoot: URL
  ) throws -> ReviewedQemuLaunchResources {
    var base = configuration
    base.supportMedia = nil
    let original = try registeredEvaluation(for: base, projectRoot: projectRoot)
    let loader = try sharedEvaluation(projectRoot: projectRoot)
    let currentCarrier = try acceleratedDisplaySupportImage(projectRoot: projectRoot)
    let previousCarrier = try previousAcceleratedDisplaySupportImage(projectRoot: projectRoot)
    let carrier: ReviewedQemuSupportImage?
    if let path = configuration.supportMedia {
      if path == currentCarrier.url.path {
        carrier = currentCarrier
      } else if path == previousCarrier.url.path {
        carrier = previousCarrier
      } else {
        throw registeredQemuFailure()
      }
    } else {
      carrier = nil
    }
    let graphics = [
      ReviewedQemuLibrary(
        url: projectRoot.appendingPathComponent(
          ".lab/qemu-neptune-port-20261013/graphics/lib/libEGL.dylib"),
        byteCount: 44800,
        sha256: "3e785489890ddd72e2e44973446193c07cfe2bcae10398a42da4c6f4cba04699",
        importPaths: [
          "/Users/developer/Documents/Code/VM/macOpenVM/.lab/qemu-neptune-port-20261013/graphics/lib/libEGL.dylib",
          "/Users/developer/Documents/Code/VM/macOpenVM/.lab/qemu-neptune-port-20261013/graphics/lib/EGL.framework/Versions/Current/EGL",
        ], dependencies: ["/usr/lib/libc++.1.dylib", "/usr/lib/libSystem.B.dylib"]),
      ReviewedQemuLibrary(
        url: projectRoot.appendingPathComponent(
          ".lab/qemu-neptune-port-20261013/graphics/lib/libGLESv2.dylib"),
        byteCount: 6_288_416,
        sha256: "aecfa5754684f0a4adbe8590ad3c8ffc38d416119006530a5fbb3ab5132a32ec",
        importPaths: [
          "/Users/developer/Documents/Code/VM/macOpenVM/.lab/qemu-neptune-port-20261013/graphics/lib/libGLESv2.dylib",
          "/Users/developer/Documents/Code/VM/macOpenVM/.lab/qemu-neptune-port-20261013/graphics/lib/GLESv2.framework/Versions/Current/GLESv2",
        ],
        dependencies: [
          "/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore",
          "/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
          "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
          "/System/Library/Frameworks/IOSurface.framework/Versions/A/IOSurface",
          "/System/Library/Frameworks/Metal.framework/Versions/A/Metal",
          "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", "/usr/lib/libz.1.dylib",
          "/usr/lib/libobjc.A.dylib", "/usr/lib/libc++.1.dylib", "/usr/lib/libSystem.B.dylib",
          "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
        ]),
      ReviewedQemuLibrary(
        url: projectRoot.appendingPathComponent(
          ".lab/neptune-protocol2-20261016/graphics/lib/libdxmt-native.dylib"),
        byteCount: 29_390_752,
        sha256: "2967b3869e6223a436f054380af29d0077c89d4d61736647857e732a04fbc2df",
        importPaths: [
          "/Users/developer/Documents/Code/VM/macOpenVM/.lab/neptune-protocol2-20261016/graphics/lib/libdxmt-native.dylib"
        ],
        dependencies: [
          "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
          "/System/Library/Frameworks/Metal.framework/Versions/A/Metal",
          "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
          "/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
          "/System/Library/Frameworks/ColorSync.framework/Versions/A/ColorSync",
          "/System/Library/Frameworks/MetalFX.framework/Versions/A/MetalFX",
          "/usr/lib/libsqlite3.dylib", "/usr/lib/libSystem.B.dylib", "/usr/lib/libz.1.dylib",
          "/usr/lib/libncurses.5.4.dylib", "/usr/lib/libc++.1.dylib",
          "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
          "/usr/lib/libobjc.A.dylib",
        ]),
      ReviewedQemuLibrary(
        url: projectRoot.appendingPathComponent(
          ".lab/qemu-neptune-port-20261013/graphics/lib/libepoxy.0.dylib"),
        byteCount: 1_333_200,
        sha256: "918f267b27411463b39691209493f8e4ba02a4d2b5de37a321f30d03a939b65c",
        importPaths: [
          "/Users/developer/Documents/Code/VM/macOpenVM/.lab/qemu-neptune-port-20261013/graphics/lib/libepoxy.0.dylib"
        ], dependencies: ["/usr/lib/libSystem.B.dylib"]),
      ReviewedQemuLibrary(
        url: projectRoot.appendingPathComponent(
          ".lab/unified-graphics-20261018/renderer/prefix/lib/libvirglrenderer.1.dylib"),
        byteCount: 2_100_736,
        sha256: "bcbf40ec2c2521a5a53730fa994fa778fb0efe5f05a8019af28e802ce2195f6e",
        importPaths: [
          "/Users/developer/Documents/Code/VM/macOpenVM/.lab/unified-graphics-20261018/renderer/prefix/lib/libvirglrenderer.1.dylib"
        ],
        dependencies: [
          "/usr/lib/libSystem.B.dylib",
          "/Users/developer/Documents/Code/VM/macOpenVM/.lab/qemu-neptune-port-20261013/graphics/lib/libepoxy.0.dylib",
          "/System/Library/Frameworks/Metal.framework/Versions/A/Metal", "/usr/lib/libobjc.A.dylib",
        ]),
    ]
    return try ReviewedQemuLaunchResources(
      creation: original.creation, libraries: loader.libraries + graphics,
      qemuImports: [
        "/System/Library/Frameworks/Hypervisor.framework/Versions/A/Hypervisor",
        "/opt/homebrew/opt/gnutls/lib/libgnutls.30.dylib",
        "/opt/homebrew/opt/pixman/lib/libpixman-1.0.dylib", "/usr/lib/libz.1.dylib",
        "/Users/developer/Documents/Code/VM/macOpenVM/.lab/qemu-neptune-port-20261013/graphics/lib/libepoxy.0.dylib",
        "/Users/developer/Documents/Code/VM/macOpenVM/.lab/qemu-slirp-candidate-50c20db5653a47dd8a73d36439f45e66/private-libslirp/lib/libslirp.0.dylib",
        "/opt/homebrew/opt/glib/lib/libglib-2.0.0.dylib",
        "/opt/homebrew/opt/dtc/lib/libfdt.1.dylib",
        "/Users/developer/Documents/Code/VM/macOpenVM/.lab/unified-graphics-20261018/renderer/prefix/lib/libvirglrenderer.1.dylib",
        "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
        "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
        "/System/Library/Frameworks/CoreAudio.framework/Versions/A/CoreAudio",
        "/usr/lib/libSystem.B.dylib",
        "/usr/lib/libobjc.A.dylib",
      ], swtpmImports: loader.swtpmImports,
      systemImports: loader.systemImports.union([
        "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
        "/System/Library/Frameworks/ColorSync.framework/Versions/A/ColorSync",
        "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
        "/System/Library/Frameworks/CoreAudio.framework/Versions/A/CoreAudio",
        "/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
        "/System/Library/Frameworks/Hypervisor.framework/Versions/A/Hypervisor",
        "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
        "/System/Library/Frameworks/IOSurface.framework/Versions/A/IOSurface",
        "/System/Library/Frameworks/Metal.framework/Versions/A/Metal",
        "/System/Library/Frameworks/MetalFX.framework/Versions/A/MetalFX",
        "/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore",
        "/usr/lib/libSystem.B.dylib", "/usr/lib/libc++.1.dylib", "/usr/lib/libncurses.5.4.dylib",
        "/usr/lib/libobjc.A.dylib", "/usr/lib/libsqlite3.dylib", "/usr/lib/libz.1.dylib",
      ]),
      runtimeQemu: ReviewedQemuResource(
        role: .qemu,
        url: projectRoot.appendingPathComponent(
          ".lab/unified-graphics-20261018/runtimes/accelerated/qemu-system-aarch64"),
        byteCount: 26_796_048,
        sha256: "b3f6e87446c6967eb2efefd529f9b757de08b51caa6a225c5fb0831d15070955"),
      supportsShared: original.supportsShared,
      supportImage: carrier,
      renderServer: ReviewedQemuRenderServer(
        url: projectRoot.appendingPathComponent(
          ".lab/neptune-protocol2-20261016/graphics/libexec/virgl_render_server"),
        byteCount: 1_666_624,
        sha256: "d568dd3ddf475962569628a2a90fb97cc978a7bae4cd3a356894275e2d9ed264",
        imports: ["/usr/lib/libSystem.B.dylib"]),
      // This private Windows GPU trial was installed with the UK keyboard.
      // Ordinary VM creation/launch retains its original keymap selection.
      keyboardMap: ReviewedQemuResource(
        role: .enUsKeymap,
        url: projectRoot.appendingPathComponent(
          ".lab/qemu-neptune-port-20261013/source/pc-bios/keymaps/en-gb"),
        byteCount: 29219, sha256: "e14229b7f9165bf226bf4de968fd5f6a504014a2179de08c2b2184cefe68174e"
      ), sharedFrameTransport: true, audioOutput: .coreAudioHDAV1)
  }
  public static func acceleratedDisplaySupportImage(projectRoot: URL) throws
    -> ReviewedQemuSupportImage
  {
    // Matching v0.4 drivers plus the reviewed fixed60-second R5 presenter.
    // Synthetic presentation is separate from physical scanout or game FPS.
    try ReviewedQemuSupportImage(
      url: projectRoot.appendingPathComponent(
        ".lab/manager-iteration-20261016/root-windows-graphics-tools-v9-iso1/macopenvm-graphics-check-v9.iso"
      ),
      byteCount: 6_488_064,
      sha256: "041d07817f37e1f89ff5175c98a879675be8328ab2f00e192c3154629a670056")
  }

  private static func previousAcceleratedDisplaySupportImage(projectRoot: URL) throws
    -> ReviewedQemuSupportImage
  {
    // Existing saved v8 selections retain their exact reviewed descriptor.
    try ReviewedQemuSupportImage(
      url: projectRoot.appendingPathComponent(
        ".lab/windows-gpu-driver-v04-20261015/macopenvm-graphics-check-v8.iso"),
      byteCount: 6_387_712,
      sha256: "081fbffac74f3e59f9e2256d5efc50b326b56d5911f02c49cf708ca58a4457a0")
  }
}
