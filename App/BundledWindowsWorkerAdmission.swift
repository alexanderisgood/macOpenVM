// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation
import Security

/// An actual app component, never decoded from configuration or preferences.
struct ReviewedBundledWindowsWorker: Sendable {
  let executableURL: URL
  let identifier: String
  let sha256: String
  let byteCount: UInt64
  fileprivate let admission: BundledWorkerSnapshot
  fileprivate init(_ admission: BundledWorkerSnapshot) {
    self.admission = admission
    executableURL = admission.executableURL
    identifier = admission.identifier
    sha256 = admission.sha256
    byteCount = admission.byteCount
  }
  func revalidate() throws {
    let current = try BundledWindowsWorkerAdmission.inspect(
      bundleURL: admission.bundleURL, mainExecutableURL: admission.mainExecutableURL,
      bundleIdentifier: admission.bundleIdentifier,
      signature: BundledWindowsWorkerAdmission.nativeSignature)
    guard current == admission else { throw bundledWorkerFailure() }
  }
}

enum BundledWindowsWorkerAdmission {
  static func current() throws -> ReviewedBundledWindowsWorker {
    let bundle = Bundle.main
    guard let executable = bundle.executableURL, let identifier = bundle.bundleIdentifier else {
      throw bundledWorkerFailure()
    }
    return ReviewedBundledWindowsWorker(
      try inspect(
        bundleURL: bundle.bundleURL,
        mainExecutableURL: executable, bundleIdentifier: identifier, signature: nativeSignature))
  }

  /// Controlled tests receive a snapshot only; this seam cannot mint the reviewed runtime value.
  static func inspect(
    bundleURL: URL, mainExecutableURL: URL, bundleIdentifier: String,
    signature: (URL, String, Bool) throws -> Void = nativeSignature
  ) throws -> BundledWorkerSnapshot {
    guard BundledWorkerIO.local(bundleURL), BundledWorkerIO.local(mainExecutableURL),
      mainExecutableURL.deletingLastPathComponent().path == bundleURL.path + "/Contents/MacOS",
      bundleIdentifier.utf8.count <= 240, !bundleIdentifier.isEmpty,
      bundleIdentifier.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
          || $0 == 46
      })
    else { throw bundledWorkerFailure() }
    let macos = mainExecutableURL.deletingLastPathComponent()
    let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    let worker = macos.appendingPathComponent("macopenvm-worker")
    let descriptor = resources.appendingPathComponent("macopenvm-worker.json")
    let directories = try [bundleURL, macos, resources].map(BundledWorkerIO.directory)
    try signature(bundleURL, bundleIdentifier, false)
    let identifier = bundleIdentifier + ".worker"
    let helper = try BundledWorkerIO.read(worker, mode: 0o500, maximum: 134_217_728, hashOnly: true)
    let record = try BundledWorkerIO.read(descriptor, mode: 0o600, maximum: 1024, hashOnly: false)
    // Packaging writes these exact five sorted scalar fields. Comparing expected bytes
    // rejects duplicate/unknown fields and parser aliases without trusting a decoded graph.
    let expected = Data(
      """
      {
        "bytes": \(helper.state.size),
        "identifier": "\(identifier)",
        "schemaVersion": 1,
        "scope": "macopenvm-bundled-worker",
        "sha256": "\(helper.sha256)"
      }

      """.utf8)
    guard record.data == expected else { throw bundledWorkerFailure() }
    try signature(worker, identifier, true)
    try signature(bundleURL, bundleIdentifier, false)
    let checkedDirectories = try [bundleURL, macos, resources].map(BundledWorkerIO.directory)
    guard directories == checkedDirectories,
      try BundledWorkerIO.named(worker) == helper.state,
      try BundledWorkerIO.named(descriptor) == record.state
    else { throw bundledWorkerFailure() }
    return BundledWorkerSnapshot(
      bundleURL: bundleURL, mainExecutableURL: mainExecutableURL,
      bundleIdentifier: bundleIdentifier, executableURL: worker, identifier: identifier,
      sha256: helper.sha256, byteCount: UInt64(helper.state.size),
      helperIdentity: helper.state, descriptorIdentity: record.state, directories: directories)
  }

  static func nativeSignature(_ url: URL, identifier: String, worker: Bool) throws {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
      SecRequirementCreateWithString(
        ("identifier \"" + identifier + "\"") as CFString, [], &requirement) == errSecSuccess,
      let requirement,
      SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
        == errSecSuccess
    else { throw bundledWorkerFailure() }
    if worker {
      var information: CFDictionary?
      guard
        SecCodeCopySigningInformation(
          code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
        let fields = information as? [String: Any],
        let entitlements = fields[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
        entitlements.count == 1,
        let enabled = entitlements["com.apple.security.virtualization"] as? NSNumber,
        CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue
      else { throw bundledWorkerFailure() }
    }
  }
}

struct BundledWorkerSnapshot: Equatable, Sendable {
  let bundleURL: URL, mainExecutableURL: URL, bundleIdentifier: String
  let executableURL: URL, identifier: String, sha256: String, byteCount: UInt64
  fileprivate let helperIdentity: BundledWorkerFileState
  fileprivate let descriptorIdentity: BundledWorkerFileState
  fileprivate let directories: [BundledWorkerFileState]
}

private struct BundledWorkerFileState: Equatable, Sendable {
  let device: Int32, inode: UInt64, size: Int64, mode: UInt16, uid: UInt32, gid: UInt32,
    links: UInt16
  let modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
  init(_ s: stat) {
    device = s.st_dev
    inode = s.st_ino
    size = s.st_size
    mode = s.st_mode
    uid = s.st_uid
    gid = s.st_gid
    links = s.st_nlink
    modifiedSeconds = s.st_mtimespec.tv_sec
    modifiedNanoseconds = s.st_mtimespec.tv_nsec
    changedSeconds = s.st_ctimespec.tv_sec
    changedNanoseconds = s.st_ctimespec.tv_nsec
  }
}

private enum BundledWorkerIO {
  static func local(_ url: URL) -> Bool {
    url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
      && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
      && url.path.hasPrefix("/") && url.path.utf8.count <= 4096
      && !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      && url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".."
      })
  }
  static func directory(_ url: URL) throws -> BundledWorkerFileState {
    guard local(url) else { throw bundledWorkerFailure() }
    var path = ""
    for part in url.path.split(separator: "/") {
      path += "/" + part
      var s = stat()
      guard lstat(path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR,
        s.st_uid == 0 || s.st_uid == geteuid(),
        s.st_mode & 0o022 == 0
          || (path == "/private/tmp" && s.st_uid == 0 && s.st_mode & S_ISVTX != 0)
      else { throw bundledWorkerFailure() }
    }
    return try named(url)
  }
  static func named(_ url: URL) throws -> BundledWorkerFileState {
    var s = stat()
    guard lstat(url.path, &s) == 0 else { throw bundledWorkerFailure() }
    return BundledWorkerFileState(s)
  }
  static func read(_ url: URL, mode: mode_t, maximum: Int, hashOnly: Bool) throws
    -> (state: BundledWorkerFileState, sha256: String, data: Data)
  {
    let parent = url.deletingLastPathComponent()
    let beforeParent = try directory(parent)
    let anchor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard anchor >= 0 else { throw bundledWorkerFailure() }
    defer { close(anchor) }
    var openedParent = stat()
    guard fstat(anchor, &openedParent) == 0, BundledWorkerFileState(openedParent) == beforeParent
    else { throw bundledWorkerFailure() }
    let fd = openat(anchor, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw bundledWorkerFailure() }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == 0 || before.st_uid == geteuid(), before.st_nlink == 1,
      before.st_mode & 0o7777 == mode, before.st_size > 0, before.st_size <= maximum
    else { throw bundledWorkerFailure() }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    var count = 0
    var hasher = SHA256()
    var bytes = Data()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      count += chunk.count
      guard count <= before.st_size else { throw bundledWorkerFailure() }
      hasher.update(data: chunk)
      if !hashOnly { bytes.append(chunk) }
    }
    var after = stat()
    var named = stat()
    var afterParent = stat()
    let identity = BundledWorkerFileState(before)
    guard fstat(fd, &after) == 0,
      fstatat(anchor, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
      count == before.st_size, identity == BundledWorkerFileState(after),
      identity == BundledWorkerFileState(named),
      fstat(anchor, &afterParent) == 0, beforeParent == BundledWorkerFileState(afterParent),
      try directory(parent) == beforeParent
    else { throw bundledWorkerFailure() }
    return (identity, hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
  }
}

private func bundledWorkerFailure() -> VMError {
  VMError(
    .unsupported, "The app’s bundled Windows worker could not be confirmed.",
    recovery: "Use the verified app build and preserve any existing VM session.")
}
