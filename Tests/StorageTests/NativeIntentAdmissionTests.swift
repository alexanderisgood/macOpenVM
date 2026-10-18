// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import CryptoKit
import Darwin
import Foundation
import Testing
import VMStorage

private struct NativeFileWitness: Equatable {
  let device: dev_t
  let inode: ino_t
  let mode: mode_t
  let length: off_t
  let links: UInt16
  let modifiedSeconds: Int
  let modifiedNanoseconds: Int
  let changedSeconds: Int
  let changedNanoseconds: Int
  let digest: Data
}

private func nativeMetadataMatches(_ lhs: stat, _ rhs: stat) -> Bool {
  lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_uid == rhs.st_uid
    && lhs.st_mode == rhs.st_mode && lhs.st_size == rhs.st_size && lhs.st_nlink == rhs.st_nlink
    && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
    && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
    && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
}

/// Private fixture inventory only; no decoded path is opened and no file is written.
private func nativeIntentInventory(_ directory: URL) throws -> [String: NativeFileWitness] {
  let manager = FileManager.default
  guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
    throw VMError(.storage, "Cannot inspect the private fixture.", recovery: "Preserve it.")
  }
  var result: [String: NativeFileWitness] = [:]
  var total: UInt64 = 0
  for case let url as URL in enumerator {
    guard result.count < 64 else {
      throw VMError(.storage, "Fixture inventory exceeded its bound.", recovery: "Preserve it.")
    }
    var named = stat()
    guard lstat(url.path, &named) == 0, named.st_uid == getuid(),
      named.st_mode & 0o022 == 0,
      named.st_mode & S_IFMT == S_IFDIR || named.st_mode & S_IFMT == S_IFREG
    else { throw VMError(.storage, "Unsafe fixture entry.", recovery: "Preserve it.") }
    var hash = SHA256()
    if named.st_mode & S_IFMT == S_IFREG {
      guard named.st_size >= 0, named.st_size <= 134_217_728, named.st_nlink == 1 else {
        throw VMError(.storage, "Unbounded fixture file.", recovery: "Preserve it.")
      }
      total += UInt64(named.st_size)
      guard total <= 268_435_456 else {
        throw VMError(.storage, "Fixture data exceeded its bound.", recovery: "Preserve it.")
      }
      let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard fd >= 0 else {
        throw VMError(.storage, "Cannot open a fixture entry safely.", recovery: "Preserve it.")
      }
      defer { close(fd) }
      var opened = stat()
      guard fstat(fd, &opened) == 0, nativeMetadataMatches(named, opened)
      else { throw VMError(.storage, "Fixture entry changed.", recovery: "Preserve it.") }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
      var bytes = 0
      while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
        bytes += chunk.count
        guard bytes <= named.st_size else {
          throw VMError(.storage, "Fixture entry grew.", recovery: "Preserve it.")
        }
        hash.update(data: chunk)
      }
      guard bytes == named.st_size else {
        throw VMError(.storage, "Fixture entry changed length.", recovery: "Preserve it.")
      }
      var final = stat()
      var namedAfter = stat()
      guard fstat(fd, &final) == 0, lstat(url.path, &namedAfter) == 0,
        nativeMetadataMatches(named, final), nativeMetadataMatches(named, namedAfter)
      else {
        throw VMError(.storage, "Fixture entry changed during hashing.", recovery: "Preserve it.")
      }
    }
    result[String(url.path.dropFirst(directory.path.count + 1))] = NativeFileWitness(
      device: named.st_dev, inode: named.st_ino, mode: named.st_mode, length: named.st_size,
      links: named.st_nlink, modifiedSeconds: named.st_mtimespec.tv_sec,
      modifiedNanoseconds: named.st_mtimespec.tv_nsec, changedSeconds: named.st_ctimespec.tv_sec,
      changedNanoseconds: named.st_ctimespec.tv_nsec, digest: Data(hash.finalize()))
  }
  return result
}

@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["MACOPENVM_NATIVE_INTENT_FIXTURE"] != nil,
    "Requires an explicit preserved no-OS hard-worker-loss fixture with an available kernel lease and unsettled intent."
  ))
func nativeInterruptedIntentAdmission() async throws {
  let raw = try #require(ProcessInfo.processInfo.environment["MACOPENVM_NATIVE_INTENT_FIXTURE"])
  let directory = URL(fileURLWithPath: raw, isDirectory: true)
  try #require(raw.hasPrefix("/") && raw == directory.standardizedFileURL.path)
  let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  try #require(
    directory.deletingLastPathComponent().path == project.appendingPathComponent(".lab").path)
  try #require(
    directory.lastPathComponent.range(
      of: "^windows-efi-probe-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}$", options: .regularExpression)
      != nil)
  var current = URL(fileURLWithPath: "/", isDirectory: true)
  for component in directory.pathComponents.dropFirst() {
    current.appendPathComponent(component, isDirectory: true)
    var info = stat()
    try #require(lstat(current.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR)
    try #require((info.st_uid == 0 || info.st_uid == getuid()) && info.st_mode & 0o022 == 0)
  }
  let files = VMFiles()
  let intent = try #require(try await files.readRuntimeIntent(in: directory))
  try #require(intent.state == .unsettled)
  try #require(await files.writerStatus(in: directory) == .available)
  let before = try nativeIntentInventory(directory)
  for expectedID in [intent.vmID, nil] {
    do {
      let forbidden = try VMLock(directory: directory, expectedVMID: expectedID)
      withExtendedLifetime(forbidden) {}
      Issue.record("Actual unsettled intent wrongly admitted a cooperating writer.")
    } catch let error as VMError {
      #expect(error.code == .busy)
    }
  }
  #expect(try await files.readRuntimeIntent(in: directory) == intent)
  #expect(await files.writerStatus(in: directory) == .available)
  #expect(try nativeIntentInventory(directory) == before)
}
