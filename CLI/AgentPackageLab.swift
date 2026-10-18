// SPDX-License-Identifier: Apache-2.0
import AgentProtocol
import Foundation
import VMStorage

enum AgentPackageLab {
  static func verify(directory: URL, approvedIssuer: String) async throws
    -> AgentPackageVerification
  {
    let files = VMFiles()
    let manifest = try await files.readMetadata(
      at: directory.appendingPathComponent("SHA256SUMS"),
      limit: AgentPackageVerifier.maximumManifestBytes)
    let signature = try await files.readMetadata(
      at: directory.appendingPathComponent("manifest.sig"), limit: 64)
    let publicKey = try await files.readMetadata(
      at: directory.appendingPathComponent("issuer.raw"), limit: 32)
    var payload: [String: Data] = [:]
    for name in AgentPackageVerifier.fileNames {
      guard let limit = AgentPackageVerifier.maximumFileBytes[name] else {
        throw AgentPackageError.invalidManifest
      }
      payload[name] = try await files.readMetadata(
        at: directory.appendingPathComponent(name), limit: limit)
    }
    return try AgentPackageVerifier.verify(
      manifest: manifest, signature: signature, issuerPublicKey: publicKey,
      approvedIssuerSHA256: approvedIssuer, files: payload)
  }
}
