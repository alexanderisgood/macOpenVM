// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation

public enum QemuCreationResourceRole: String, Codable, CaseIterable, Sendable {
  case qemu, swtpm, firmware, enUsKeymap
}

/// Expected bytes approved independently by the caller/code review, never by saved VM metadata.
public struct ReviewedQemuResource: Equatable, Sendable {
  public let role: QemuCreationResourceRole
  public let url: URL
  public let byteCount: UInt64
  public let sha256: String

  public init(role: QemuCreationResourceRole, url: URL, byteCount: UInt64, sha256: String) {
    self.role = role
    self.url = url
    self.byteCount = byteCount
    self.sha256 = sha256
  }
}

/// Creation binding for the reviewed offline ARM64 Windows evaluation profile.
/// This does not close Homebrew dylib/dependency, release, or Windows-health qualification.
public struct ReviewedQemuCreationResources: Equatable, Sendable {
  public static let profile = "experimental-windows-arm64-offline-v1"
  public static let minimumHostMajorVersion = 27
  public let resources: [ReviewedQemuResource]
  public let uefiVariablesTemplate: Data

  public init(resources: [ReviewedQemuResource], uefiVariablesTemplate: Data = Data()) throws {
    guard resources.count == QemuCreationResourceRole.allCases.count,
      Set(resources.map(\.role)) == Set(QemuCreationResourceRole.allCases),
      Set(resources.map { $0.url.path }).count == resources.count,
      // The actual reviewed uefi-vars-sysbus fresh-store input is an empty file,
      // not an invented JSON document or a copy of an existing VM's trust store.
      uefiVariablesTemplate.isEmpty
    else { throw qemuCreationFailure(.invalidConfiguration) }
    for resource in resources { try QemuCreationResourceIO.validateDescription(resource) }
    var ordered: [ReviewedQemuResource] = []
    for role in QemuCreationResourceRole.allCases {
      guard let resource = resources.first(where: { $0.role == role }) else {
        throw qemuCreationFailure(.invalidConfiguration)
      }
      ordered.append(resource)
    }
    self.resources = ordered
    self.uefiVariablesTemplate = uefiVariablesTemplate
  }

  public func resource(_ role: QemuCreationResourceRole) throws -> ReviewedQemuResource {
    guard let resource = resources.first(where: { $0.role == role }) else {
      throw qemuCreationFailure(.invalidConfiguration)
    }
    return resource
  }

  public func verifyResourceFiles() throws {
    for resource in resources { try QemuCreationResourceIO.verify(resource) }
  }
}

/// Saved data is provenance only. Admission requires the independently reviewed bundle and VM.
public enum QemuPlatformIdentityCodec {
  public static let maximumBytes = 8192
  public static let filename = "qemu-platform.json"
  public static let variablesFilename = "uefi-vars.json"
  public static let tpmDirectory = "tpm-state"

  public static func encode(
    for configuration: VMConfiguration, resources: ReviewedQemuCreationResources
  ) throws -> Data {
    guard configuration.guest == .windows11, configuration.backend == .qemuHVF,
      configuration.architecture == .arm64, configuration.boot == .efi
    else { throw qemuCreationFailure(.invalidConfiguration) }
    let record = Record(
      schemaVersion: 1, vmID: configuration.id,
      profile: ReviewedQemuCreationResources.profile,
      minimumHostMajorVersion: ReviewedQemuCreationResources.minimumHostMajorVersion,
      resources: resources.resources.map {
        Resource(role: $0.role, path: $0.url.path, byteCount: $0.byteCount, sha256: $0.sha256)
      }, variablesFilename: variablesFilename,
      variablesTemplateByteCount: resources.uefiVariablesTemplate.count,
      variablesTemplateSHA256: digest(resources.uefiVariablesTemplate), tpmDirectory: tpmDirectory)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(record)
    guard bytes.count <= maximumBytes else { throw qemuCreationFailure(.invalidConfiguration) }
    return bytes
  }

  /// Exact canonical bytes reject unknown/duplicate keys and arbitrary nested input
  /// without constructing an untrusted object graph or deriving resource authority.
  public static func validate(
    _ data: Data, for configuration: VMConfiguration,
    resources: ReviewedQemuCreationResources
  ) throws {
    guard !data.isEmpty, data.count <= maximumBytes,
      data == (try encode(for: configuration, resources: resources))
    else { throw qemuCreationFailure(.corruptMetadata) }
  }

  private struct Record: Encodable {
    let schemaVersion: Int
    let vmID: UUID
    let profile: String
    let minimumHostMajorVersion: Int
    let resources: [Resource]
    let variablesFilename: String
    let variablesTemplateByteCount: Int
    let variablesTemplateSHA256: String
    let tpmDirectory: String
  }

  private struct Resource: Encodable {
    let role: QemuCreationResourceRole
    let path: String
    let byteCount: UInt64
    let sha256: String
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// Lexical admission is independent of whether the path already exists.
/// Foundation standardization can rewrite /private/tmp to the /tmp symlink;
/// actual ancestry is checked separately without following symbolic links.
enum QemuCreationLocalPath {
  static func isValid(_ url: URL, maximumBytes: Int) -> Bool {
    let path = url.path
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
      && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
      && path.hasPrefix("/") && path.utf8.count <= maximumBytes
      && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      && components.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}

enum QemuCreationResourceIO {
  static func validateDescription(_ resource: ReviewedQemuResource) throws {
    let url = resource.url
    let maximum: UInt64 =
      resource.role == .enUsKeymap ? 1_048_576 : resource.role == .swtpm ? 16_777_216 : 134_217_728
    guard QemuCreationLocalPath.isValid(url, maximumBytes: 2048),
      resource.byteCount > 0, resource.byteCount <= maximum, resource.sha256.utf8.count == 64,
      resource.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw qemuCreationFailure(.invalidConfiguration) }
  }

  static func verify(_ resource: ReviewedQemuResource) throws {
    try validateDescription(resource)
    var ancestor = ""
    for component in resource.url.path.split(separator: "/").dropLast() {
      ancestor += "/" + component
      var info = stat()
      guard lstat(ancestor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
        throw qemuCreationFailure(.storage)
      }
    }
    let descriptor = open(resource.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw qemuCreationFailure(.storage) }
    defer { close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0, safe(before),
      before.st_size >= 0, UInt64(before.st_size) == resource.byteCount,
      (resource.role != .qemu && resource.role != .swtpm) || before.st_mode & 0o111 != 0
    else { throw qemuCreationFailure(.storage) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    var hasher = SHA256()
    var count: UInt64 = 0
    do {
      while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        count += UInt64(data.count)
        guard count <= resource.byteCount else { throw qemuCreationFailure(.storage) }
        hasher.update(data: data)
      }
    } catch { throw qemuCreationFailure(.storage) }
    let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    var after = stat()
    var named = stat()
    guard count == resource.byteCount, actual == resource.sha256,
      fstat(descriptor, &after) == 0, lstat(resource.url.path, &named) == 0,
      stable(before, after), stable(after, named)
    else { throw qemuCreationFailure(.storage) }
  }

  private static func safe(_ info: stat) -> Bool {
    info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1
      && (info.st_uid == geteuid() || info.st_uid == 0) && info.st_mode & 0o022 == 0
  }

  private static func stable(_ before: stat, _ after: stat) -> Bool {
    safe(after) && before.st_dev == after.st_dev && before.st_ino == after.st_ino
      && before.st_size == after.st_size && before.st_mode == after.st_mode
      && before.st_uid == after.st_uid && before.st_gid == after.st_gid
      && before.st_nlink == after.st_nlink
      && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
      && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
      && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
      && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
  }
}

func qemuCreationFailure(_ code: VMError.Code) -> VMError {
  VMError(
    code, "The reviewed QEMU creation inputs or new identity could not be confirmed.",
    recovery: "Preserve partial new files and reviewed resources; inspect before retrying.")
}
