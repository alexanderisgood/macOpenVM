// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation

public struct AgentPackageVerification: Encodable, Equatable, Sendable {
  public let formatVersion = 1
  public let architecture = "aarch64-linux-musl"
  public let manifestSHA256: String
  public let issuerSHA256: String
  public let filesVerified: Int
}

public enum AgentPackageError: Error, Equatable, Sendable {
  case invalidManifest, unapprovedIssuer, invalidSignature, changedPayload
}

/// Verifies a generic package with an independently approved issuer pin.
/// Enrollment credentials are separate and never included in this package manifest.
public enum AgentPackageVerifier {
  public static let fileNames = ["agent", "initd", "setup.sh"]
  public static let maximumManifestBytes = 512
  /// Match installer admission before loading signed package files into memory.
  public static let maximumFileBytes = [
    "agent": 16 * 1_048_576, "initd": 16_384, "setup.sh": 131_072,
  ]
  public static let signingContext = Data("macOpenVM Linux agent package v1\n".utf8)
  public static func verify(
    manifest: Data, signature: Data, issuerPublicKey: Data, approvedIssuerSHA256: String,
    files: [String: Data]
  ) throws -> AgentPackageVerification {
    guard manifest.count <= maximumManifestBytes, issuerPublicKey.count == 32,
      signature.count == 64,
      isDigest(approvedIssuerSHA256), digest(issuerPublicKey) == approvedIssuerSHA256
    else { throw AgentPackageError.unapprovedIssuer }
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: issuerPublicKey),
      key.isValidSignature(signature, for: signingContext + manifest)
    else { throw AgentPackageError.invalidSignature }
    guard let text = String(data: manifest, encoding: .utf8), text.hasSuffix("\n"),
      text.utf8.allSatisfy({ $0 == 10 || (32...126).contains($0) })
    else { throw AgentPackageError.invalidManifest }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count == fileNames.count + 1, lines.last?.isEmpty == true,
      Set(files.keys) == Set(fileNames)
    else { throw AgentPackageError.invalidManifest }
    for (index, name) in fileNames.enumerated() {
      let line = String(lines[index])
      guard line.count == 66 + name.count, line.hasSuffix("  " + name),
        isDigest(String(line.prefix(64)))
      else { throw AgentPackageError.invalidManifest }
      guard let data = files[name], let limit = maximumFileBytes[name],
        !data.isEmpty, data.count <= limit,
        digest(data) == String(line.prefix(64))
      else { throw AgentPackageError.changedPayload }
    }
    return .init(
      manifestSHA256: digest(manifest), issuerSHA256: approvedIssuerSHA256,
      filesVerified: fileNames.count)
  }

  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func isDigest(_ text: String) -> Bool {
    text.utf8.count == 64
      && text.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
      }
  }
}
