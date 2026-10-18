// SPDX-License-Identifier: Apache-2.0
import AgentProtocol
import CryptoKit
import Foundation
import Testing

@Suite struct AgentPackageTests {
  private func package() throws -> (Data, Data, Data, String, [String: Data]) {
    let key = Curve25519.Signing.PrivateKey()
    let files = Dictionary(
      uniqueKeysWithValues: AgentPackageVerifier.fileNames.map {
        ($0, Data(("Original package test " + $0).utf8))
      })
    let manifest = Data(
      AgentPackageVerifier.fileNames.map {
        AgentPackageVerifier.digest(files[$0] ?? Data()) + "  " + $0 + "\n"
      }.joined().utf8)
    let signature = try key.signature(for: AgentPackageVerifier.signingContext + manifest)
    let publicKey = key.publicKey.rawRepresentation
    return (manifest, signature, publicKey, AgentPackageVerifier.digest(publicKey), files)
  }

  @Test func validSignedPayloadHasExactManifestAndSeparateEnrollment() throws {
    let (manifest, signature, publicKey, pin, files) = try package()
    let result = try AgentPackageVerifier.verify(
      manifest: manifest, signature: signature, issuerPublicKey: publicKey,
      approvedIssuerSHA256: pin, files: files)
    #expect(
      result.filesVerified == 3 && result.manifestSHA256 == AgentPackageVerifier.digest(manifest))
    #expect(!AgentPackageVerifier.fileNames.contains("key.pem"))
  }

  @Test(arguments: ["pin", "signature", "manifest", "file", "extra", "missing"])
  func alteredOrUnapprovedPackageIsRejected(_ mutation: String) throws {
    var (manifest, signature, publicKey, pin, files) = try package()
    switch mutation {
    case "pin": pin = String(repeating: "0", count: 64)
    case "signature": signature[0] ^= 1
    case "manifest": manifest[0] ^= 1
    case "file": files["agent"] = Data("changed".utf8)
    case "extra": files["key.pem"] = Data("must remain separate".utf8)
    case "missing": files.removeValue(forKey: "initd")
    default: break
    }
    #expect(throws: AgentPackageError.self) {
      try AgentPackageVerifier.verify(
        manifest: manifest, signature: signature, issuerPublicKey: publicKey,
        approvedIssuerSHA256: pin, files: files)
    }
  }

  @Test func validSignatureCannotAuthorizeAnUnsafeManifestShape() throws {
    let key = Curve25519.Signing.PrivateKey()
    for text in ["", String(repeating: "a", count: 1025), "../agent\n", "bad\0manifest\n"] {
      let manifest = Data(text.utf8)
      let signature = try key.signature(for: AgentPackageVerifier.signingContext + manifest)
      #expect(throws: AgentPackageError.self) {
        try AgentPackageVerifier.verify(
          manifest: manifest, signature: signature,
          issuerPublicKey: key.publicKey.rawRepresentation,
          approvedIssuerSHA256: AgentPackageVerifier.digest(key.publicKey.rawRepresentation),
          files: [:])
      }
    }
  }

  @Test(arguments: ["agent", "initd", "setup.sh"])
  func authenticatedPayloadMustFitItsInstallerFileBoundary(_ name: String) throws {
    let key = Curve25519.Signing.PrivateKey()
    // Installer contract, independently stated rather than deriving a policy
    // expectation from the verifier being checked.
    let limits = ["agent": 16 * 1_048_576, "initd": 16_384, "setup.sh": 131_072]
    let limit = try #require(limits[name])
    let publicKey = key.publicKey.rawRepresentation
    let pin = AgentPackageVerifier.digest(publicKey)
    for extra in [0, 1] {
      var files = Dictionary(
        uniqueKeysWithValues: AgentPackageVerifier.fileNames.map { ($0, Data([0x41])) })
      files[name] = Data(repeating: 0x42, count: limit + extra)
      let manifest = Data(
        AgentPackageVerifier.fileNames.map {
          AgentPackageVerifier.digest(files[$0] ?? Data()) + "  " + $0 + "\n"
        }.joined().utf8)
      let signature = try key.signature(for: AgentPackageVerifier.signingContext + manifest)
      if extra == 0 {
        let result = try AgentPackageVerifier.verify(
          manifest: manifest, signature: signature, issuerPublicKey: publicKey,
          approvedIssuerSHA256: pin, files: files)
        #expect(result.filesVerified == 3)
      } else {
        #expect(throws: AgentPackageError.changedPayload) {
          try AgentPackageVerifier.verify(
            manifest: manifest, signature: signature, issuerPublicKey: publicKey,
            approvedIssuerSHA256: pin, files: files)
        }
      }
    }
  }
}
