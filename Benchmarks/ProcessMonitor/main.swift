// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Darwin
import Foundation
import Qemu

/// A host-process monitor microbenchmark, with two system sleep children and no VM.
@main struct ProcessMonitorBenchmark {
  static func main() async {
    do { try await run() } catch {
      FileHandle.standardError.write(
        Data("Process monitor measurement failed; preserve its private output.\n".utf8))
      exit(1)
    }
  }

  private static func run() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 10 else { throw MeasurementFailure.invalidArguments }
    var options: [String: String] = [:]
    let allowed: Set<String> = [
      "--label", "--source", "--expected-source-sha256", "--output", "--seconds",
    ]
    for index in stride(from: 0, to: arguments.count, by: 2) {
      guard allowed.contains(arguments[index]), options[arguments[index]] == nil else {
        throw MeasurementFailure.invalidArguments
      }
      options[arguments[index]] = arguments[index + 1]
    }
    guard let label = options["--label"], ["before-polling", "after-exit-event"].contains(label),
      let source = options["--source"], source.hasPrefix("/"),
      let expectedHash = options["--expected-source-sha256"], expectedHash.count == 64,
      let output = options["--output"], output.hasPrefix("/"), !output.contains("\0"),
      let rawSeconds = options["--seconds"], let seconds = Int(rawSeconds),
      (2...15).contains(seconds),
      try hash(source, maximum: 1_048_576) == expectedHash
    else { throw MeasurementFailure.invalidArguments }
    let null = open("/dev/null", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard null >= 0 else { throw MeasurementFailure.io }
    defer { close(null) }
    var children: [LeaseSpawn.Child] = []
    let before = try ResourceSnapshot.capture()
    let start = ContinuousClock.now
    do {
      for _ in 0..<2 {
        let child = try await LeaseSpawn.spawn(
          configuration: .init(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: [String(seconds)],
            environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
            workingDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            standardInput: null, standardOutput: null, standardError: null,
            inheritedDescriptors: []))
        children.append(child)
      }
      for child in children {
        let result = try await child.wait()
        guard result.status == 0, !result.wasSignalled else { throw MeasurementFailure.childExit }
      }
    } catch {
      let owned = children
      let cleanup = Task {
        for child in owned {
          try? await child.terminate()
          _ = try? await child.wait()
        }
      }
      await cleanup.value
      throw error
    }
    let elapsed = start.duration(to: .now)
    let after = try ResourceSnapshot.capture()
    guard try hash(source, maximum: 1_048_576) == expectedHash else {
      throw MeasurementFailure.sourceChanged
    }
    let record = Measurement(
      schemaVersion: 1, scope: "host-process-monitor-feasibility", label: label,
      sourceSHA256: expectedHash,
      executableSHA256: try hash(CommandLine.arguments[0], maximum: 67_108_864),
      hostOS: ProcessInfo.processInfo.operatingSystemVersionString,
      sleepChildren: 2, requestedSeconds: seconds,
      elapsedSeconds: Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18,
      parentUserCPUSeconds: Double(after.userMicroseconds - before.userMicroseconds) / 1e6,
      parentSystemCPUSeconds: Double(after.systemMicroseconds - before.systemMicroseconds) / 1e6,
      parentVoluntaryContextSwitches: after.voluntarySwitches - before.voluntarySwitches,
      parentInvoluntaryContextSwitches: after.involuntarySwitches - before.involuntarySwitches,
      guestPerformanceVerified: false, energyOrWakeupsVerified: false)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(record)
    let fd = open(output, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw MeasurementFailure.io }
    defer { close(fd) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let written = write(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { throw MeasurementFailure.io }
        offset += written
      }
    }
    guard fsync(fd) == 0 else { throw MeasurementFailure.io }
    print("Host process monitor measurement saved; no guest or energy claim.")
  }

  private static func hash(_ path: String, maximum: Int) throws -> String {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw MeasurementFailure.io }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_nlink == 1, before.st_size >= 0, before.st_size <= maximum
    else { throw MeasurementFailure.io }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    var digest = SHA256()
    var total = 0
    while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
      total += chunk.count
      guard total <= maximum else { throw MeasurementFailure.io }
      digest.update(data: chunk)
    }
    var after = stat()
    guard fstat(fd, &after) == 0, total == before.st_size,
      before.st_ino == after.st_ino, before.st_dev == after.st_dev,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    else { throw MeasurementFailure.sourceChanged }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

private enum MeasurementFailure: Error {
  case invalidArguments, io, childExit, sourceChanged
}

private struct ResourceSnapshot {
  let userMicroseconds: Int64
  let systemMicroseconds: Int64
  let voluntarySwitches: Int64
  let involuntarySwitches: Int64

  static func capture() throws -> Self {
    var info = rusage()
    guard getrusage(RUSAGE_SELF, &info) == 0 else { throw MeasurementFailure.io }
    return Self(
      userMicroseconds: Int64(info.ru_utime.tv_sec) * 1_000_000 + Int64(info.ru_utime.tv_usec),
      systemMicroseconds: Int64(info.ru_stime.tv_sec) * 1_000_000 + Int64(info.ru_stime.tv_usec),
      voluntarySwitches: Int64(info.ru_nvcsw), involuntarySwitches: Int64(info.ru_nivcsw))
  }
}

private struct Measurement: Encodable {
  let schemaVersion: Int
  let scope: String
  let label: String
  let sourceSHA256: String
  let executableSHA256: String
  let hostOS: String
  let sleepChildren: Int
  let requestedSeconds: Int
  let elapsedSeconds: Double
  let parentUserCPUSeconds: Double
  let parentSystemCPUSeconds: Double
  let parentVoluntaryContextSwitches: Int64
  let parentInvoluntaryContextSwitches: Int64
  let guestPerformanceVerified: Bool
  let energyOrWakeupsVerified: Bool
}
