// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation

public enum ConfigurationCodec {
  public static let maximumBytes = 65_536
  public static func decode(_ data: Data) throws -> VMConfiguration {
    guard data.count <= maximumBytes else { throw invalid() }
    do {
      let c = try JSONDecoder().decode(VMConfiguration.self, from: data)
      guard c.schemaVersion == 1 else { throw invalid() }
      return c
    } catch { throw invalid() }
  }
  public static func encode(_ configuration: VMConfiguration) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(configuration)
    guard data.count <= maximumBytes, configuration.schemaVersion == 1 else { throw invalid() }
    return data
  }
  private static func invalid() -> VMError {
    VMError(
      .corruptMetadata, "Configuration is malformed, oversized, or has an unknown schema.",
      recovery:
        "Use read-only inspection and restore a known-good configuration; do not overwrite guest disks."
    )
  }
}
