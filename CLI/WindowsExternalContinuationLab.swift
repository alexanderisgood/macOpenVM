// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation
import Security
import VMCore
import VMStorage

/// One explicit relocation/continuation of the retained Windows evaluation VM.
/// Disk records correlate a reviewed previous run; only a new actual writer and
/// RecordedRuntimeOwner mint the next session. No process is started by this actor.
actor WindowsExternalContinuationFiles {
  static let vmID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")
  static let previousSessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")
  static let destinationPath =
    "/Users/developer/Library/Application Support/macOpenVM/PrivateEvaluation/11111111-1111-4111-8111-111111111111"
  static let macAddress = "02:11:22:33:44:55"
  static let displayScope = "approved-windows-external-continuation-display-route"
  private let files = LabRuntimeFiles()

  static var project: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  }
  static var sourcePath: String {
    project.path + "/.lab/windows-installer-boot-6223442a7c544aa8a7f17061aec76f80"
  }

  func prepare(
    directory: URL, recordURL: URL, recordSHA256: String,
    runDirectory: URL, lock: VMLock
  ) async throws -> WindowsExternalPrepared {
    guard let vmID = Self.vmID, let previous = Self.previousSessionID,
      directory.path == Self.destinationPath, WindowsExternalFileIO.lexical(directory),
      lock.owns(directory),
      runDirectory.deletingLastPathComponent().path == directory.path + "/continuation-runs",
      runDirectory.lastPathComponent.range(of: "^run-[0-9a-f]{32}$", options: .regularExpression)
        != nil,
      recordURL.path == runDirectory.path + "/external-prepared.json"
    else { throw windowsExternalFailure() }
    let bytes = try WindowsExternalFileIO.readPrivate(recordURL, maximum: 32768)
    let record = try WindowsExternalAdmission.decode(
      bytes, sha256: recordSHA256,
      sourcePath: Self.sourcePath, directory: directory, runDirectory: runDirectory,
      vmID: vmID, previousSessionID: previous)
    try WindowsExternalFileIO.privateDirectory(directory)
    try WindowsExternalFileIO.privateDirectory(runDirectory.deletingLastPathComponent())
    try WindowsExternalFileIO.privateDirectory(runDirectory)
    let required = Set([
      "external-prepared.json", "relocation-receipt.json", "previous-runtime.json",
      "previous-intent.json",
      "previous-worker-result.json", "normal-stop.json", "parent-stdout.log", "parent-stderr.log",
    ])
    guard Set(try FileManager.default.contentsOfDirectory(atPath: runDirectory.path)) == required
    else {
      throw windowsExternalFailure()
    }
    _ = try WindowsExternalFileIO.readPrivate(
      runDirectory.appendingPathComponent("relocation-receipt.json"), maximum: 32768)
    for name in ["parent-stdout.log", "parent-stderr.log"] {
      try WindowsExternalFileIO.requireRegular(
        runDirectory.appendingPathComponent(name), mode: 0o600, maximum: 1_048_576)
    }
    try await verifyRetainedState(
      record, directory: directory, runDirectory: runDirectory, lock: lock)
    let short = URL(fileURLWithPath: record.socketDirectory, isDirectory: true)
    try WindowsExternalFileIO.privateDirectory(short)
    guard try FileManager.default.contentsOfDirectory(atPath: short.path).isEmpty else {
      throw windowsExternalFailure()
    }
    try await verifyAssets(directory)
    // Recheck the exact previous owner and resources after all awaited reads.
    try await verifyRetainedState(
      record, directory: directory, runDirectory: runDirectory, lock: lock)
    let input = Self.input(directory: directory, short: short)
    try await files.saveBytes(
      bytes, at: runDirectory.appendingPathComponent("admitted-external-prepared.json"))
    try await files.saveBytes(
      Data("approved-same-vm-windows-external-continuation\n".utf8),
      at: runDirectory.appendingPathComponent("external-continuation.claim"))
    return WindowsExternalPrepared(record: record, input: input)
  }

  func verifyRetainedState(
    _ record: WindowsExternalPreparation, directory: URL,
    runDirectory: URL, lock: VMLock
  ) async throws {
    guard lock.owns(directory), record.destinationDirectory == directory.path,
      record.runDirectory == runDirectory.path
    else { throw windowsExternalFailure() }
    var root = stat()
    guard lstat(directory.path, &root) == 0, UInt64(root.st_dev) == record.directoryDevice,
      UInt64(root.st_ino) == record.directoryInode
    else { throw windowsExternalFailure() }
    let historyBytes = try WindowsExternalFileIO.readPrivate(
      directory.appendingPathComponent("runtime.json"), maximum: 4096)
    let intentBytes = try WindowsExternalFileIO.readPrivate(
      directory.appendingPathComponent("runtime-intent.json"), maximum: 4096)
    guard windowsExternalDigest(historyBytes) == record.previousRuntimeSHA256,
      windowsExternalDigest(intentBytes) == record.previousIntentSHA256,
      try WindowsExternalFileIO.readPrivate(
        runDirectory.appendingPathComponent("previous-runtime.json"), maximum: 4096)
        == historyBytes,
      try WindowsExternalFileIO.readPrivate(
        runDirectory.appendingPathComponent("previous-intent.json"), maximum: 4096) == intentBytes
    else { throw windowsExternalFailure() }
    let history = try RuntimeHistoryCodec.decode(historyBytes)
    let intent = try await VMFiles().readRuntimeIntent(in: directory)
    guard history.sessionID == record.previousSessionID, history.snapshot.outcome == .guestStopped,
      history.snapshot.state == .stopped, !history.snapshot.backendActive,
      history.snapshot.operation == nil,
      intent?.vmID == record.vmID, intent?.sessionID == record.previousSessionID,
      intent?.state == .settled
    else { throw windowsExternalFailure() }
    let resultBytes = try WindowsExternalFileIO.readPrivate(
      runDirectory.appendingPathComponent("previous-worker-result.json"), maximum: 32768)
    let result = try JSONDecoder().decode(WindowsExternalPreviousResult.self, from: resultBytes)
    guard windowsExternalDigest(resultBytes) == record.previousWorkerResultSHA256,
      result.status == "passed", result.runtimeIntentSettled, result.drainsFinished,
      result.readonlyHashesPreserved, result.qemuExit == 0, result.tpmExit == 0,
      windowsExternalDigest(
        try WindowsExternalFileIO.readPrivate(
          runDirectory.appendingPathComponent("normal-stop.json"), maximum: 32768))
        == record.normalStopRecordSHA256
    else { throw windowsExternalFailure() }
    try WindowsExternalFileIO.verifyResources(record, directory: directory)
    guard lock.owns(directory), try await VMFiles().readRuntimeIntent(in: directory) == intent,
      try WindowsExternalFileIO.readPrivate(
        directory.appendingPathComponent("runtime.json"), maximum: 4096) == historyBytes
    else { throw windowsExternalFailure() }
  }

  func verifyAssets(_ directory: URL) async throws {
    let root = Self.project.appendingPathComponent(".lab")
    let candidate = root.appendingPathComponent(
      "qemu-slirp-candidate-50c20db5653a47dd8a73d36439f45e66")
    for parent in [
      candidate, candidate.appendingPathComponent("private-libslirp/lib"),
      candidate.appendingPathComponent("source/pc-bios/keymaps"),
    ] {
      try WindowsExternalFileIO.checkAncestry(parent)
    }
    let qemu = candidate.appendingPathComponent("qemu-system-aarch64")
    try await files.verify(
      qemu, length: 26_746_208,
      digest: "e2e40cce3cd0b394bb45190ec759bd33c7882bf65e186f4cdf2b5c4d9a7a3745", mode: 0o500)
    try Self.verifyHypervisorSignature(qemu)
    try await files.verify(
      candidate.appendingPathComponent("private-libslirp/lib/libslirp.0.dylib"),
      length: 156_992, digest: "10d404d8a693f2d37401ce0ff54e71d9ffb4a5fe42335a360dea39e6d083a5ab",
      mode: nil)
    try await files.verify(
      candidate.appendingPathComponent("source/pc-bios/keymaps/en-us"),
      length: 27_086, digest: "52cf4c523e686078699ed58761c7e1443080305237a5f67a3716832570c5c8e5",
      mode: 0o600)
    try await files.verify(
      directory.appendingPathComponent("firmware-code.fd"), length: 67_108_864,
      digest: "28bc28488baa2d77f3bdd5e9187dbcc8d9c1a7eb809545340b5f7348a9a39532", mode: 0o400)
    let media = root.appendingPathComponent(
      "windows-media-48f5f2b7600e4010b813985fcea79ef8/Windows11_Client_arm64_en-us_26300_9457.iso.partial"
    )
    let driver = root.appendingPathComponent(
      "windows-network-support-aeb3fb95ab7d42f3b0ef8437b6edbb09/macopenvm-driver-evaluation.iso")
    for asset in [media, driver] {
      try WindowsExternalFileIO.checkAncestry(asset.deletingLastPathComponent())
    }
    try await files.verify(
      media, length: 8_528_523_264,
      digest: "8992f2d2cfd2fa647e579e9eb31fc21f34da8333c29b6170fde17d2ed6623e9c", mode: 0o600)
    try await files.verify(
      driver, length: 921_600,
      digest: "7c510ac451f1a692571eb8df408ddde36afd86ddff88281d366a2fc887ef2394", mode: 0o400)
    try await files.verify(
      URL(fileURLWithPath: "/opt/homebrew/Cellar/swtpm/0.10.2/bin/swtpm"),
      length: 72_192, digest: "538a2dbbadcf907fb3910aa69e11b7c80d333950731809ade67129eda80c9a7a",
      mode: nil)
  }

  private static func verifyHypervisorSignature(_ url: URL) throws {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
      SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        == errSecSuccess
    else { throw windowsExternalFailure() }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let dictionary = information as? [String: Any],
      let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
      let enabled = entitlements["com.apple.security.hypervisor"] as? NSNumber,
      CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue
    else { throw windowsExternalFailure() }
  }

  static func input(directory: URL, short: URL) -> LabRuntimeInput {
    let root = project.path + "/.lab"
    let candidate = root + "/qemu-slirp-candidate-50c20db5653a47dd8a73d36439f45e66"
    let data = candidate + "/source/pc-bios"
    let tpm = "/opt/homebrew/Cellar/swtpm/0.10.2/bin/swtpm"
    let args = [
      candidate + "/qemu-system-aarch64", "-no-user-config", "-nodefaults", "-machine",
      "virt-11.1,acpi=on,gic-version=3,secure=off,virtualization=off", "-accel", "hvf", "-cpu",
      "host",
      "-smp", "4", "-m", "6144", "-display", "none", "-monitor", "none", "-serial", "stdio",
      "-netdev",
      "user,id=net0,ipv4=on,ipv6=off,restrict=off,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3,dhcpstart=10.0.2.15",
      "-device",
      "virtio-net-pci,id=nic0,netdev=net0,disable-legacy=on,disable-modern=off,mac=\(macAddress)",
      "-qmp", "unix:\(short.path)/qmp.sock,server=on,wait=off", "-drive",
      "if=pflash,unit=0,format=raw,readonly=on,file=\(directory.path)/firmware-code.fd", "-device",
      "uefi-vars-sysbus,jsonfile=\(directory.path)/uefi-vars.json,size=262144,force-secure-boot=off,disable-custom-mode=on",
      "-chardev", "socket,id=chrtpm,path=\(short.path)/tpm.sock", "-tpmdev",
      "emulator,id=tpm0,chardev=chrtpm",
      "-device", "tpm-tis-device,tpmdev=tpm0,ppi=on", "-device", "ramfb,id=display0",
      "-device", "qemu-xhci,id=xhci0", "-device", "usb-kbd,id=keyboard0,bus=xhci0.0",
      "-device", "usb-tablet,id=pointer0,bus=xhci0.0", "-drive",
      "if=none,id=installer,format=raw,media=cdrom,readonly=on,file=\(root)/windows-media-48f5f2b7600e4010b813985fcea79ef8/Windows11_Client_arm64_en-us_26300_9457.iso.partial",
      "-device", "usb-storage,drive=installer,bus=xhci0.0,bootindex=1", "-drive",
      "if=none,id=target,format=raw,file=\(directory.path)/blank-nvme.raw", "-device",
      "nvme,drive=target,serial=MVO-NEW-WIN-BOOT",
      "-L", data, "-k", data + "/keymaps/en-us", "-vnc",
      "unix:\(short.path)/vnc.sock,share=force-shared",
      "-drive",
      "if=none,id=networkdrivers,format=raw,media=cdrom,readonly=on,file=\(root)/windows-network-support-aeb3fb95ab7d42f3b0ef8437b6edbb09/macopenvm-driver-evaluation.iso",
      "-device", "usb-storage,drive=networkdrivers,bus=xhci0.0",
    ]
    return LabRuntimeInput(
      schemaVersion: 1, scope: "approved-same-vm-windows-external-fixture",
      qemuArgv: args,
      swtpmArgv: [
        tpm, "socket", "--tpm2", "--tpmstate", "dir=\(directory.path)/tpm-state,mode=0600,lock",
        "--ctrl", "type=unixio,path=\(short.path)/tpm.sock,mode=0600,terminate", "--flags",
        "startup-none", "--log", "file=-",
      ],
      environment: [
        "PATH": "/usr/bin:/bin:/opt/homebrew/bin", "LC_ALL": "C", "TMPDIR": short.path,
      ],
      qmpSocket: short.path + "/qmp.sock", tpmSocket: short.path + "/tpm.sock",
      guestLaunched: false, windowsCompatibilityVerified: false)
  }
}

struct WindowsExternalPrepared: Sendable {
  let record: WindowsExternalPreparation
  let input: LabRuntimeInput
}
struct WindowsExternalFileIdentity: Codable, Equatable, Sendable {
  let device: UInt64, inode: UInt64, byteCount: UInt64
  let mode: UInt16
}
struct WindowsExternalTPMIdentity: Codable, Equatable, Sendable {
  let device: UInt64, inode: UInt64, byteCount: UInt64
  let mode: UInt16
  let sha256: String
}
struct WindowsExternalPreparation: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let scope: String
  let vmID: UUID, previousSessionID: UUID
  let sourceDirectory: String, destinationDirectory: String, runDirectory: String,
    socketDirectory: String, macAddress: String
  let directoryDevice: UInt64, directoryInode: UInt64
  let previousRuntimeSHA256: String, previousIntentSHA256: String,
    previousWorkerResultSHA256: String, normalStopRecordSHA256: String
  let actualOwnerReaped: Bool, allChildrenTerminal: Bool, drainsFinished: Bool, pipesClosed: Bool,
    leasesClosed: Bool
  let runtimeIntentSettled: Bool, normalStopRequested: Bool, relocationApproved: Bool,
    continuationApproved: Bool
  let forceStopUsed: Bool, qemuSignalled: Bool, tpmSignalled: Bool
  let workerExit: Int, qemuExit: Int, tpmExit: Int
  let resources: [String: WindowsExternalFileIdentity]
  let tpmFiles: [String: WindowsExternalTPMIdentity]
}
struct WindowsExternalPreviousResult: Decodable {
  let status: String
  let runtimeIntentSettled: Bool, drainsFinished: Bool, readonlyHashesPreserved: Bool
  let qemuExit: Int, tpmExit: Int
}

enum WindowsExternalAdmission {
  static func encode(_ record: WindowsExternalPreparation) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(record)
    guard !bytes.isEmpty, bytes.count <= 32768 else { throw windowsExternalFailure() }
    return bytes
  }
  static func decode(
    _ bytes: Data, sha256: String, sourcePath: String, directory: URL,
    runDirectory: URL, vmID: UUID, previousSessionID: UUID
  ) throws -> WindowsExternalPreparation {
    guard !bytes.isEmpty, bytes.count <= 32768, validHash(sha256),
      windowsExternalDigest(bytes) == sha256
    else {
      throw windowsExternalFailure()
    }
    var parser = WindowsExternalJSONFields(bytes: Array(bytes))
    try parser.parse()
    let r = try JSONDecoder().decode(WindowsExternalPreparation.self, from: bytes)
    let raw = try JSONSerialization.jsonObject(with: bytes)
    let expected = try JSONSerialization.jsonObject(with: encode(r))
    guard
      try JSONSerialization.data(
        withJSONObject: raw, options: [.sortedKeys, .withoutEscapingSlashes])
        == JSONSerialization.data(
          withJSONObject: expected, options: [.sortedKeys, .withoutEscapingSlashes]),
      r.schemaVersion == 1, r.scope == "approved-same-vm-windows-external-preparation",
      r.vmID == vmID, r.previousSessionID == previousSessionID, r.sourceDirectory == sourcePath,
      r.destinationDirectory == directory.path, r.runDirectory == runDirectory.path,
      r.macAddress == WindowsExternalContinuationFiles.macAddress,
      r.socketDirectory.range(
        of: "^/private/tmp/mvo-win-external-[0-9a-f]{16}$", options: .regularExpression) != nil,
      r.actualOwnerReaped, r.allChildrenTerminal, r.drainsFinished, r.pipesClosed, r.leasesClosed,
      r.runtimeIntentSettled, r.normalStopRequested, r.relocationApproved, r.continuationApproved,
      !r.forceStopUsed, !r.qemuSignalled, !r.tpmSignalled, r.workerExit == 0, r.qemuExit == 0,
      r.tpmExit == 0,
      Set(r.resources.keys) == [
        "blank-nvme.raw", "firmware-code.fd", "uefi-vars.json", "writer.lock", "tpm-state",
      ],
      Set(r.tpmFiles.keys) == [".lock", "tpm2-00.permall"], r.directoryInode > 0
    else { throw windowsExternalFailure() }
    for hash in [
      r.previousRuntimeSHA256, r.previousIntentSHA256, r.previousWorkerResultSHA256,
      r.normalStopRecordSHA256,
    ] {
      guard validHash(hash) else { throw windowsExternalFailure() }
    }
    for item in r.tpmFiles.values {
      guard item.inode > 0, item.byteCount <= 16_777_216, item.mode == 0o600, validHash(item.sha256)
      else {
        throw windowsExternalFailure()
      }
    }
    return r
  }
  static func validHash(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

/// Three object levels only; no arrays/floating values, bounded decoded keys,
/// and escaped duplicate keys rejected before Foundation can collapse them.
private struct WindowsExternalJSONFields {
  let bytes: [UInt8]
  var index = 0
  var current: UInt8? { index < bytes.count ? bytes[index] : nil }
  mutating func parse() throws {
    try object(depth: 0)
    whitespace()
    guard index == bytes.count else { throw windowsExternalFailure() }
  }
  mutating func object(depth: Int) throws {
    guard depth <= 2 else { throw windowsExternalFailure() }
    try consume(123)
    var keys: Set<String> = []
    while true {
      whitespace()
      if current == 125 {
        index += 1
        return
      }
      guard keys.count < 64 else { throw windowsExternalFailure() }
      let span = try string()
      let key = try JSONDecoder().decode(String.self, from: Data(bytes[span]))
      guard keys.insert(key).inserted else { throw windowsExternalFailure() }
      try consume(58)
      whitespace()
      if current == 123 {
        try object(depth: depth + 1)
      } else if current == 34 {
        _ = try string()
      } else {
        let start = index
        while let byte = current, ![44, 125, 9, 10, 13, 32].contains(byte) { index += 1 }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        guard
          token == "true" || token == "false"
            || token.range(of: "^-?[0-9]+$", options: .regularExpression) != nil
        else { throw windowsExternalFailure() }
      }
      whitespace()
      if current == 125 {
        index += 1
        return
      }
      try consume(44)
      whitespace()
      guard current != 125 else { throw windowsExternalFailure() }
    }
  }
  mutating func string() throws -> Range<Int> {
    whitespace()
    let start = index
    try consume(34)
    var escaped = false
    while let byte = current {
      index += 1
      guard byte >= 32 else { throw windowsExternalFailure() }
      if escaped {
        escaped = false
      } else if byte == 92 {
        escaped = true
      } else if byte == 34 {
        return start..<index
      }
    }
    throw windowsExternalFailure()
  }
  mutating func consume(_ byte: UInt8) throws {
    whitespace()
    guard current == byte else { throw windowsExternalFailure() }
    index += 1
  }
  mutating func whitespace() {
    while let byte = current, [9, 10, 13, 32].contains(byte) { index += 1 }
  }
}

enum WindowsExternalFileIO {
  static func lexical(_ url: URL) -> Bool {
    let path = url.path
    return url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
      && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
      && path.hasPrefix("/") && path.utf8.count <= 4096
      && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      && path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
      }
  }
  static func checkAncestry(_ url: URL) throws {
    guard lexical(url) else { throw windowsExternalFailure() }
    var path = ""
    for component in url.path.split(separator: "/") {
      path += "/" + component
      var info = stat()
      guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == 0 || info.st_uid == geteuid(),
        info.st_mode & 0o022 == 0 || path == "/private/tmp"
      else { throw windowsExternalFailure() }
    }
  }
  static func privateDirectory(_ url: URL) throws {
    try checkAncestry(url)
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700
    else {
      throw windowsExternalFailure()
    }
  }
  static func requireRegular(_ url: URL, mode: mode_t, maximum: UInt64) throws {
    try checkAncestry(url.deletingLastPathComponent())
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
      info.st_nlink == 1, info.st_mode & 0o7777 == mode, info.st_size >= 0,
      UInt64(info.st_size) <= maximum
    else {
      throw windowsExternalFailure()
    }
  }
  static func readPrivate(_ url: URL, maximum: Int) throws -> Data {
    try requireRegular(url, mode: 0o600, maximum: UInt64(maximum))
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw windowsExternalFailure() }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0 else { throw windowsExternalFailure() }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    var data = Data()
    while let chunk = try handle.read(upToCount: min(4096, maximum - data.count + 1)),
      !chunk.isEmpty
    {
      data.append(chunk)
      guard data.count <= maximum else { throw windowsExternalFailure() }
    }
    var after = stat()
    var named = stat()
    guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0, before.st_dev == after.st_dev,
      before.st_ino == after.st_ino, after.st_dev == named.st_dev, after.st_ino == named.st_ino,
      before.st_size == after.st_size, data.count == after.st_size, before.st_mode == after.st_mode,
      after.st_mode == named.st_mode, before.st_uid == after.st_uid, after.st_uid == geteuid(),
      after.st_nlink == 1, named.st_nlink == 1,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw windowsExternalFailure() }
    return data
  }
  static func verifyResources(_ record: WindowsExternalPreparation, directory: URL) throws {
    for (name, item) in record.resources {
      let path = directory.appendingPathComponent(name)
      var info = stat()
      let mode: mode_t = name == "firmware-code.fd" ? 0o400 : name == "tpm-state" ? 0o700 : 0o600
      guard lstat(path.path, &info) == 0,
        info.st_mode & S_IFMT == (name == "tpm-state" ? S_IFDIR : S_IFREG),
        info.st_uid == geteuid(), info.st_mode & 0o7777 == mode, item.mode == mode,
        UInt64(info.st_dev) == item.device, UInt64(info.st_ino) == item.inode,
        info.st_size >= 0, UInt64(info.st_size) == item.byteCount,
        name == "tpm-state" || info.st_nlink == 1,
        name != "blank-nvme.raw" || item.byteCount == 64 * 1_073_741_824,
        name != "writer.lock" || item.byteCount == 0,
        name != "uefi-vars.json" || item.byteCount <= 1_048_576
      else { throw windowsExternalFailure() }
    }
    let tpm = directory.appendingPathComponent("tpm-state")
    try privateDirectory(tpm)
    guard
      Set(try FileManager.default.contentsOfDirectory(atPath: tpm.path))
        == Set(record.tpmFiles.keys)
    else { throw windowsExternalFailure() }
    for (name, item) in record.tpmFiles {
      let path = tpm.appendingPathComponent(name)
      let bytes = try readPrivate(path, maximum: 16_777_216)
      var info = stat()
      guard lstat(path.path, &info) == 0, UInt64(info.st_dev) == item.device,
        UInt64(info.st_ino) == item.inode,
        UInt64(info.st_size) == item.byteCount, windowsExternalDigest(bytes) == item.sha256
      else { throw windowsExternalFailure() }
    }
  }
}
func windowsExternalDigest(_ bytes: Data) -> String {
  SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
func windowsExternalFailure() -> VMError {
  VMError(
    .invalidConfiguration, "The reviewed external Windows continuation could not be confirmed.",
    recovery:
      "Preserve the actual owner, relocated VM and previous records; inspect before retrying.")
}

/// The real sealed receipt supplies the retained directory anchor. Platform
/// flush uncertainty is caught by RecordedRuntimeOwner before settled intent.
struct WindowsExternalRuntimeStore: RecordedRuntimeStore {
  let lock: VMLock
  private let files = VMFiles()
  func beginOwnership(in directory: URL, vmID: UUID, lock: VMLock) async throws
    -> RuntimeSessionPermit
  {
    guard self.lock === lock else { throw windowsExternalFailure() }
    return try await files.beginRuntimeSession(in: directory, forVMID: vmID, lock: lock)
  }
  func commitOwnership(in directory: URL, receipt: RuntimeSettlementReceipt) async throws {
    guard receipt.permit.owns(lock), lock.owns(directory) else { throw windowsExternalFailure() }
    try receipt.permit.withSettlementDirectory(in: directory) { anchor in
      try WindowsExternalPlatformFlush.flush(at: anchor)
    }
    try await files.commitRuntimeSettlement(in: directory, receipt: receipt)
  }
  func status(at url: URL) async -> VMFileStatus { await files.status(at: url) }
  func readOwnershipIntent(in directory: URL) async throws -> RuntimeIntent? {
    try await files.readRuntimeIntent(in: directory)
  }
  func inspectWritableFile(at url: URL) async throws -> DiskUsage {
    try await files.inspectWritableFile(at: url)
  }
  func readMetadata(at url: URL, limit: Int) async throws -> Data {
    try await files.readMetadata(at: url, limit: limit)
  }
  func checkFreeSpace(at directory: URL, reserveBytes: UInt64) async throws {
    try await files.checkFreeSpace(at: directory, reserveBytes: reserveBytes)
  }
  func writeNewMetadata(_ data: Data, at url: URL) async throws {
    try await files.writeNewMetadata(data, at: url)
  }
  func atomicWrite(_ data: Data, at url: URL) async throws {
    try await files.atomicWrite(data, at: url)
  }
}

enum WindowsExternalPlatformFlush {
  static func flush(at anchor: Int32, synchronize: (Int32) throws -> Void = synchronizeDescriptor)
    throws
  {
    for (name, maximum) in [
      ("blank-nvme.raw", UInt64(64 * 1_073_741_824)), ("uefi-vars.json", UInt64(1_048_576)),
    ] {
      try file(name, at: anchor, maximum: maximum, synchronize: synchronize)
    }
    let tpm = openat(
      anchor, "tpm-state", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard tpm >= 0 else { throw windowsExternalFailure() }
    defer { close(tpm) }
    var info = stat()
    var named = stat()
    guard fstat(tpm, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
      info.st_mode & 0o7777 == 0o700
    else {
      throw windowsExternalFailure()
    }
    let copy = fcntl(tpm, F_DUPFD_CLOEXEC, 3)
    guard copy >= 0 else { throw windowsExternalFailure() }
    guard let entries = fdopendir(copy) else {
      close(copy)
      throw windowsExternalFailure()
    }
    var names: Set<String> = []
    do {
      defer { closedir(entries) }
      while true {
        errno = 0
        guard let entry = readdir(entries) else {
          guard errno == 0 else { throw windowsExternalFailure() }
          break
        }
        let name = withUnsafePointer(to: &entry.pointee.d_name) {
          $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
            String(cString: $0)
          }
        }
        if name == "." || name == ".." { continue }
        guard names.count < 2, [".lock", "tpm2-00.permall"].contains(name),
          names.insert(name).inserted
        else { throw windowsExternalFailure() }
      }
    }
    guard names == [".lock", "tpm2-00.permall"] else { throw windowsExternalFailure() }
    for name in names { try file(name, at: tpm, maximum: 16_777_216, synchronize: synchronize) }
    try synchronize(tpm)
    guard fstatat(anchor, "tpm-state", &named, AT_SYMLINK_NOFOLLOW) == 0,
      info.st_dev == named.st_dev, info.st_ino == named.st_ino,
      named.st_mode & S_IFMT == S_IFDIR, named.st_uid == geteuid(), named.st_mode & 0o7777 == 0o700
    else { throw windowsExternalFailure() }
    try synchronize(anchor)
  }
  private static func synchronizeDescriptor(_ fd: Int32) throws {
    guard fsync(fd) == 0 else { throw windowsExternalFailure() }
  }
  private static func file(
    _ name: String, at anchor: Int32, maximum: UInt64,
    synchronize: (Int32) throws -> Void
  ) throws {
    let fd = openat(anchor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw windowsExternalFailure() }
    defer { close(fd) }
    var info = stat()
    var named = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
      info.st_nlink == 1,
      info.st_mode & 0o7777 == 0o600, info.st_size >= 0, UInt64(info.st_size) <= maximum
    else { throw windowsExternalFailure() }
    try synchronize(fd)
    guard fstatat(anchor, name, &named, AT_SYMLINK_NOFOLLOW) == 0, named.st_mode == info.st_mode,
      named.st_uid == info.st_uid, named.st_nlink == 1, named.st_dev == info.st_dev,
      named.st_ino == info.st_ino,
      named.st_size == info.st_size
    else { throw windowsExternalFailure() }
  }
}
