// SPDX-License-Identifier: Apache-2.0
import AgentProtocol
import AppleVz
import BackendAPI
import Foundation
import VMStorage
import Virtualization

@MainActor enum AgentGuestTransportLab {
  static func validate(directory: URL, configuration: VMConfiguration, socketPath: String) throws {
    let parent = directory.deletingLastPathComponent().lastPathComponent
    let prefix = "agent-guest-"
    guard directory.lastPathComponent == "Agent.macopenvm", parent.hasPrefix(prefix),
      parent.count == prefix.count + 32,
      parent.dropFirst(prefix.count).utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      }), configuration.guest == .linux, configuration.backend == .appleVz,
      configuration.network == .disconnected, configuration.diskFile == "disk.raw",
      configuration.boot == .linuxKernel,
      socketPath.hasPrefix("/private/tmp/mvo-agent-tls-"), socketPath.hasSuffix("/relay.sock")
    else {
      throw VMError(
        .invalidConfiguration, "Select a fresh offline agent transport fixture.",
        recovery: "Preserve existing VMs and use the explicit lab runner.")
    }
    if configuration.supportMedia == nil {
      guard configuration.installationMedia == nil,
        configuration.kernelArguments.hasPrefix("console=hvc0 root=UUID="),
        configuration.kernelArguments.hasSuffix(
          "rootfstype=ext4 rootflags=ro modules=virtio_blk,virtio_mmio,ext4")
      else {
        throw VMError(
          .invalidConfiguration, "Select the disc-detached installed agent fixture.",
          recovery: "Preserve its normal installed boot selection.")
      }
    }
  }

  static func attempts(_ text: String?) throws -> [Int] {
    guard let text else { return [1, 2] }
    let parts = text.split(separator: ",", omittingEmptySubsequences: false)
    let values = parts.compactMap { Int($0) }
    guard !parts.isEmpty, parts.count <= 8, values.count == parts.count,
      values.allSatisfy({ (1...8).contains($0) }), Set(values).count == values.count,
      values == values.sorted(), values.map(String.init).joined(separator: ",") == text
    else {
      throw VMError(
        .invalidConfiguration, "Choose at most eight distinct ordered lab requests.",
        recovery: "Use explicit request numbers from 1 through 8.")
    }
    return values
  }

  static func run(backend: AppleVirtualMachine, directory: URL, socketPath: String, attempts: [Int])
    async throws
  {
    for attempt in attempts {
      do {
        try await runConnection(
          backend: backend, directory: directory, socketPath: socketPath, attempt: attempt)
      } catch is CancellationError { throw CancellationError() } catch {
        FileHandle.standardError.write(
          Data("mvo.host-agent.connection-closed-with-error attempt=\(attempt)\n".utf8))
      }
      FileHandle.standardError.write(
        Data("mvo.host-agent.connection-finished attempt=\(attempt)\n".utf8))
    }
  }

  private static func runConnection(
    backend: AppleVirtualMachine, directory: URL, socketPath: String, attempt: Int
  ) async throws {
    // This notification permits one transport attempt only; it is not peer authentication.
    let notification = directory.appendingPathComponent("agent-connect-\(attempt).request")
    let files = VMFiles()
    let end = ContinuousClock.now + .seconds(180)
    while !FileManager.default.fileExists(atPath: notification.path) {
      try Task.checkCancellation()
      guard backend.isActive, ContinuousClock.now < end else {
        throw VMError(
          .backendFailure, "The guest agent transport was not requested.",
          recovery: "Preserve the fixture and inspect its guest console.")
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard try await files.readMetadata(at: notification, limit: 32) == Data("connect\n".utf8),
      let device = backend.machine.socketDevices.first as? VZVirtioSocketDevice
    else { throw AgentCiphertextRelayError.invalidEndpoint }
    let connecting = Task { @MainActor in
      try await AppleGuestSocketSession.connect(to: device, port: 4050)
    }
    let deadline = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      connecting.cancel()
    }
    defer { deadline.cancel() }
    let session = try await withTaskCancellationHandler {
      try await connecting.value
    } onCancel: {
      connecting.cancel()
    }
    defer { session.close() }
    deadline.cancel()
    try await session.withFileDescriptor { descriptor in
      try await AgentCiphertextRelay.run(
        borrowedGuestDescriptor: descriptor, socketPath: socketPath, deadlineSeconds: 30,
        onReady: {
          FileHandle.standardError.write(
            Data("mvo.host-agent.relay-ready attempt=\(attempt)\n".utf8))
        })
    }
    withExtendedLifetime(backend) {}
  }
}
