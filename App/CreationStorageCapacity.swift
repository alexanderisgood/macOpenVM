// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftUI
import VMStorage

/// A point-in-time host capacity reading, never a reservation or OS size estimate.
@MainActor final class CreationStorageAdvisor: ObservableObject {
  enum Reading: Equatable {
    case unknown, loading
    case available(UInt64)
    case unavailable
  }
  typealias Provider = @Sendable (URL) async throws -> UInt64
  static let minimumCreationBytes: UInt64 = 1_073_741_824
  @Published private(set) var reading = Reading.unknown
  @Published private(set) var parent: URL?
  @Published private(set) var refreshRevision = UUID()
  private let provider: Provider
  private var generation = UUID()

  init(provider: @escaping Provider = CreationStorageAdvisor.readCapacity) {
    self.provider = provider
  }

  nonisolated private static func readCapacity(at parent: URL) async throws -> UInt64 {
    try Task.checkCancellation()
    return try await Task.detached(priority: .utility) {
      try await VMFiles().availableStorageCapacity(at: parent)
    }.value
  }

  func requestRefresh() {
    generation = UUID()
    reading = parent == nil ? .unknown : .loading
    refreshRevision = UUID()
  }

  func refresh(parent: URL?) async {
    let current = UUID()
    generation = current
    self.parent = parent
    guard let parent else {
      reading = .unknown
      return
    }
    reading = .loading
    do {
      let bytes = try await provider(parent)
      guard !Task.isCancelled, generation == current, self.parent == parent else { return }
      reading = .available(bytes)
    } catch {
      guard !Task.isCancelled, generation == current, self.parent == parent else { return }
      reading = .unavailable
    }
  }

  func invalidate() {
    generation = UUID()
    parent = nil
    reading = .unknown
  }

  func canCreate(in selectedParent: URL?) -> Bool {
    guard let selectedParent, selectedParent == parent, case .available(let bytes) = reading
    else { return false }
    return bytes >= Self.minimumCreationBytes
  }

  func growthDeficit(diskGiB: Int) -> UInt64? {
    guard (1...2048).contains(diskGiB), case .available(let bytes) = reading else { return nil }
    let requested = UInt64(diskGiB) * Self.minimumCreationBytes
    return requested > bytes ? requested - bytes : nil
  }
}

@MainActor struct CreationStorageCapacityView: View {
  @ObservedObject var advisor: CreationStorageAdvisor
  let parent: URL?
  let diskGiB: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Available host space").font(.callout.weight(.medium))
        Spacer()
        Button("Refresh", systemImage: "arrow.clockwise", action: advisor.requestRefresh)
          .vmGlassControl().disabled(parent == nil)
          .accessibilityLabel("Refresh available host space")
      }
      switch advisor.reading {
      case .unknown:
        Text("Choose a destination to check available space.")
      case .loading:
        ProgressView("Checking available space…").controlSize(.small)
      case .unavailable:
        Text("Available space could not be checked. Refresh or choose another destination.")
      case .available(let bytes):
        Text(Self.space(bytes)).accessibilityLabel("Available host space: \(Self.space(bytes))")
        if bytes < CreationStorageAdvisor.minimumCreationBytes {
          Text("Creation needs at least 1 GiB available. Free space or choose another destination.")
        }
        if let deficit = advisor.growthDeficit(diskGiB: diskGiB) {
          Text(
            "The virtual disk can grow \(Self.space(deficit)) beyond today’s available space. Choose a smaller disk, another destination, or free space before it grows."
          )
        }
      }
      Text(
        "Virtual disk capacity is its growth limit. Sparse storage uses host space as the guest writes data."
      )
      Text(
        "This reading does not reserve space or estimate the installation size. Creation checks free space again."
      )
    }
    .font(.caption).vmSupportingText()
    .task(id: Probe(parent: parent, revision: advisor.refreshRevision)) {
      await advisor.refresh(parent: parent)
    }
    .onDisappear { advisor.invalidate() }
  }

  private struct Probe: Equatable {
    let parent: URL?
    let revision: UUID
  }
  private static func space(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
  }
}
