// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Darwin
import Foundation

/// File-only preparation for the reviewed experimental Windows profile. This does
/// not launch QEMU/swtpm, enroll firmware trust, generate keys, or change readiness.
@MainActor public struct QemuCreationPlatform: VMCreationPlatform {
  public let backend = BackendID.qemuHVF
  public let resources: ReviewedQemuCreationResources
  private let hostOverride: HostResources?

  public init(resources: ReviewedQemuCreationResources) {
    self.resources = resources
    hostOverride = nil
  }

  // Internal fixture seam. Public construction rechecks the actual host on
  // every validation, including the validation repeated by createIdentity.
  init(resources: ReviewedQemuCreationResources, host: HostResources) {
    self.resources = resources
    hostOverride = host
  }

  public func validateHost(for configuration: VMConfiguration) throws {
    try Self.validateConfiguration(
      configuration, host: hostOverride ?? .current,
      operatingSystemMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    try resources.verifyResourceFiles()
    // This file-only seam does not establish executable architecture, an actual
    // QEMU Hypervisor entitlement, dependency closure or launch authority. Those
    // must be checked again by the later registered worker before any process.
  }

  public func createIdentity(for configuration: VMConfiguration, in directory: URL) throws
    -> CreatedPlatformIdentity
  {
    try validateHost(for: configuration)
    let record = try QemuPlatformIdentityCodec.encode(for: configuration, resources: resources)
    try QemuCreationIdentityIO.create(
      configuration: configuration, in: directory,
      variables: resources.uefiVariablesTemplate, record: record)
    return CreatedPlatformIdentity(
      files: [QemuPlatformIdentityCodec.variablesFilename, QemuPlatformIdentityCodec.filename],
      emptyPrivateDirectories: [QemuPlatformIdentityCodec.tpmDirectory])
  }

  static func validateConfiguration(
    _ configuration: VMConfiguration, host: HostResources, operatingSystemMajor: Int
  ) throws {
    guard operatingSystemMajor >= ReviewedQemuCreationResources.minimumHostMajorVersion else {
      throw qemuCreationFailure(.unsupported)
    }
    try ConfigurationValidator.validate(configuration, host: host)
    let identityNames = Set([
      QemuPlatformIdentityCodec.filename, QemuPlatformIdentityCodec.variablesFilename,
      QemuPlatformIdentityCodec.tpmDirectory,
    ])
    guard configuration.guest == .windows11, configuration.backend == .qemuHVF,
      configuration.architecture == .arm64, configuration.boot == .efi,
      configuration.network == .disconnected, configuration.installationMedia != nil,
      configuration.kernel == nil, configuration.initialRamdisk == nil,
      configuration.supportMedia == nil,
      !configuration.diskFile.unicodeScalars.contains(
        where: CharacterSet.controlCharacters.contains),
      !identityNames.contains(
        configuration.diskFile.precomposedStringWithCanonicalMapping.lowercased())
    else { throw qemuCreationFailure(.invalidConfiguration) }
  }
}

enum QemuCreationIdentityIO {
  static func create(
    configuration: VMConfiguration, in directory: URL, variables: Data, record: Data
  ) throws {
    guard QemuCreationLocalPath.isValid(directory, maximumBytes: 4096),
      variables.isEmpty, record.count <= QemuPlatformIdentityCodec.maximumBytes
    else { throw qemuCreationFailure(.invalidConfiguration) }
    let anchor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard anchor >= 0 else { throw qemuCreationFailure(.storage) }
    defer { close(anchor) }
    var parent = stat()
    guard fstat(anchor, &parent) == 0, privateDirectory(parent) else {
      throw qemuCreationFailure(.storage)
    }
    // The Core creation transaction supplies only its newly empty sparse disk
    // and actual writer inode. Existing registrations, state or aliases refuse.
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    let identityNames = Set([
      QemuPlatformIdentityCodec.filename, QemuPlatformIdentityCodec.variablesFilename,
      QemuPlatformIdentityCodec.tpmDirectory,
    ])
    guard Set(names) == [configuration.diskFile, "writer.lock"], names.count == 2,
      !names.contains(where: {
        identityNames.contains($0.precomposedStringWithCanonicalMapping.lowercased())
      })
    else {
      throw qemuCreationFailure(.storage)
    }
    var disk = stat()
    var writer = stat()
    guard fstatat(anchor, configuration.diskFile, &disk, AT_SYMLINK_NOFOLLOW) == 0,
      privateFile(disk), disk.st_size >= 0, UInt64(disk.st_size) == configuration.diskBytes,
      disk.st_blocks == 0,
      fstatat(anchor, "writer.lock", &writer, AT_SYMLINK_NOFOLLOW) == 0,
      privateFile(writer), writer.st_size == 0
    else { throw qemuCreationFailure(.storage) }
    try verifyParent(anchor, directory: directory, expected: parent)
    try writeNew(variables, name: QemuPlatformIdentityCodec.variablesFilename, at: anchor)
    try writeNew(record, name: QemuPlatformIdentityCodec.filename, at: anchor)
    guard mkdirat(anchor, QemuPlatformIdentityCodec.tpmDirectory, 0o700) == 0 else {
      throw qemuCreationFailure(.storage)
    }
    try verifyParent(anchor, directory: directory, expected: parent)
    // The shared Core transaction flushes both files, the empty private child
    // and the VM directory before its final configuration registration commit.
  }

  private static func writeNew(_ bytes: Data, name: String, at anchor: Int32) throws {
    let descriptor = openat(
      anchor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw qemuCreationFailure(.storage) }
    defer { close(descriptor) }
    guard fchmod(descriptor, 0o600) == 0 else { throw qemuCreationFailure(.storage) }
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(
          descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw qemuCreationFailure(.storage) }
        offset += count
      }
    }
    var opened = stat()
    var named = stat()
    guard fstat(descriptor, &opened) == 0, privateFile(opened), opened.st_size == bytes.count,
      fstatat(anchor, name, &named, AT_SYMLINK_NOFOLLOW) == 0, privateFile(named),
      opened.st_dev == named.st_dev, opened.st_ino == named.st_ino
    else { throw qemuCreationFailure(.storage) }
  }

  private static func verifyParent(_ anchor: Int32, directory: URL, expected: stat) throws {
    var opened = stat()
    var named = stat()
    guard fstat(anchor, &opened) == 0, lstat(directory.path, &named) == 0,
      privateDirectory(opened), privateDirectory(named),
      expected.st_dev == opened.st_dev, expected.st_ino == opened.st_ino,
      opened.st_dev == named.st_dev, opened.st_ino == named.st_ino
    else { throw qemuCreationFailure(.storage) }
  }

  private static func privateDirectory(_ info: stat) -> Bool {
    info.st_mode & S_IFMT == S_IFDIR && info.st_uid == geteuid() && info.st_mode & 0o7777 == 0o700
  }

  private static func privateFile(_ info: stat) -> Bool {
    info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1
      && info.st_mode & 0o7777 == 0o600
  }
}
