// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Foundation
import Testing

@testable import MacOpenVMApp

/// Actual private regular files, mocked signatures, and snapshots only; no code is launched.
private final class BundledWorkerFixture {
  let root: URL, bundle: URL, executable: URL, worker: URL, descriptor: URL
  let identifier = "local.macOpenVM.fixture"
  let data = Data("controlled bundled helper bytes, never executable code".utf8)
  init() throws {
    root = URL(
      fileURLWithPath: "/private/tmp/worker-admission-\(UUID().uuidString)", isDirectory: true)
    bundle = root.appendingPathComponent("Fixture.app", isDirectory: true)
    executable = bundle.appendingPathComponent("Contents/MacOS/macOpenVM")
    worker = bundle.appendingPathComponent("Contents/MacOS/macopenvm-worker")
    descriptor = bundle.appendingPathComponent("Contents/Resources/macopenvm-worker.json")
    for url in [
      root, bundle, bundle.appendingPathComponent("Contents"),
      executable.deletingLastPathComponent(), descriptor.deletingLastPathComponent(),
    ] {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    try data.write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: executable.path)
    try data.write(to: worker)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: worker.path)
    try writeDescriptor()
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
  var descriptorBytes: Data {
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return Data(
      """
      {
        "bytes": \(data.count),
        "identifier": "\(identifier).worker",
        "schemaVersion": 1,
        "scope": "macopenvm-bundled-worker",
        "sha256": "\(hash)"
      }

      """.utf8)
  }
  func writeDescriptor(_ bytes: Data? = nil) throws {
    try (bytes ?? descriptorBytes).write(to: descriptor)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: descriptor.path)
  }
  func inspect(signature: (URL, String, Bool) throws -> Void = { _, _, _ in }) throws
    -> BundledWorkerSnapshot
  {
    try BundledWindowsWorkerAdmission.inspect(
      bundleURL: bundle, mainExecutableURL: executable,
      bundleIdentifier: identifier, signature: signature)
  }
}

@Suite(.serialized) struct BundledWindowsWorkerAdmissionTests {
  @Test func snapshotBindsActualSiblingBytesAndBothSignatureIdentifiers() throws {
    let f = try BundledWorkerFixture()
    defer { f.remove() }
    var calls: [(URL, String, Bool)] = []
    let admitted = try f.inspect { calls.append(($0, $1, $2)) }
    #expect(admitted.executableURL == f.worker && admitted.identifier == f.identifier + ".worker")
    #expect(admitted.byteCount == UInt64(f.data.count))
    #expect(
      admitted.sha256 == SHA256.hash(data: f.data).map { String(format: "%02x", $0) }.joined())
    #expect(calls.count == 3)
    #expect(calls[0].0 == f.bundle && calls[0].1 == f.identifier && !calls[0].2)
    #expect(calls[1].0 == f.worker && calls[1].1 == f.identifier + ".worker" && calls[1].2)
    #expect(calls[2].0 == f.bundle && !calls[2].2)
    #expect(try f.inspect() == admitted)
  }

  @Test func descriptorCannotIntroduceUnknownDuplicateOrMismatchedAuthority() throws {
    let f = try BundledWorkerFixture()
    defer { f.remove() }
    let original = String(decoding: f.descriptorBytes, as: UTF8.self)
    for text in [
      original.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": true"),
      original.replacingOccurrences(
        of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 1,\n  \"schemaVersion\": 1"),
      original.replacingOccurrences(
        of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 1,\n  \"argv\": []"),
      original.replacingOccurrences(of: ".fixture.worker", with: ".other.worker"),
      original.replacingOccurrences(of: "macopenvm-bundled-worker", with: "other-scope"),
      original.replacingOccurrences(of: "\"bytes\": \(f.data.count)", with: "\"bytes\": 1"),
    ] {
      try f.writeDescriptor(Data(text.utf8))
      #expect(throws: VMError.self) { try f.inspect() }
    }
  }

  @Test func helperModeAliasesAndReplacementRejectAdmission() throws {
    for fault in ["mode", "symlink", "hardlink", "bytes", "directory-alias"] {
      let f = try BundledWorkerFixture()
      defer { f.remove() }
      switch fault {
      case "mode":
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: f.worker.path)
      case "symlink":
        let other = f.worker.appendingPathExtension("retained")
        try FileManager.default.moveItem(at: f.worker, to: other)
        try FileManager.default.createSymbolicLink(at: f.worker, withDestinationURL: other)
      case "hardlink":
        try FileManager.default.linkItem(at: f.worker, to: f.worker.appendingPathExtension("alias"))
      case "bytes":
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: f.worker.path)
        try Data("changed helper bytes".utf8).write(to: f.worker)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o500], ofItemAtPath: f.worker.path)
      default:
        let parent = f.worker.deletingLastPathComponent()
        let other = parent.appendingPathExtension("retained")
        try FileManager.default.moveItem(at: parent, to: other)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: other)
      }
      #expect(throws: VMError.self) { try f.inspect() }
    }
  }

  @Test func descriptorModeAliasesAndSizeRejectAdmission() throws {
    for fault in ["mode", "symlink", "hardlink", "size"] {
      let f = try BundledWorkerFixture()
      defer { f.remove() }
      switch fault {
      case "mode":
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o644], ofItemAtPath: f.descriptor.path)
      case "symlink":
        let other = f.descriptor.appendingPathExtension("retained")
        try FileManager.default.moveItem(at: f.descriptor, to: other)
        try FileManager.default.createSymbolicLink(at: f.descriptor, withDestinationURL: other)
      case "hardlink":
        try FileManager.default.linkItem(
          at: f.descriptor, to: f.descriptor.appendingPathExtension("alias"))
      default: try f.writeDescriptor(Data(repeating: 32, count: 1025))
      }
      #expect(throws: VMError.self) { try f.inspect() }
    }
  }

  @Test func signatureFailureAndPostValidationReplacementCannotMintSnapshot() throws {
    let f = try BundledWorkerFixture()
    defer { f.remove() }
    for failWorker in [false, true] {
      #expect(throws: VMError.self) {
        try f.inspect { _, _, worker in
          if worker == failWorker {
            throw VMError(.unsupported, "Controlled signature rejection", recovery: "Fixture only")
          }
        }
      }
    }
    #expect(throws: VMError.self) {
      try f.inspect { url, _, worker in
        if worker {
          try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
          try Data("replaced during signature validation".utf8).write(to: url)
          try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
        }
      }
    }
  }

  @Test func onlyActualBundleSiblingLayoutCanBeInspected() throws {
    let f = try BundledWorkerFixture()
    defer { f.remove() }
    for executable in [
      f.root.appendingPathComponent("macOpenVM"),
      f.bundle.appendingPathComponent("Contents/Helpers/macOpenVM"),
    ] {
      #expect(throws: VMError.self) {
        try BundledWindowsWorkerAdmission.inspect(
          bundleURL: f.bundle, mainExecutableURL: executable,
          bundleIdentifier: f.identifier, signature: { _, _, _ in })
      }
    }
    #expect(throws: VMError.self) {
      try BundledWindowsWorkerAdmission.inspect(
        bundleURL: f.bundle, mainExecutableURL: f.executable,
        bundleIdentifier: "invalid\"identifier", signature: { _, _, _ in })
    }
  }
}
