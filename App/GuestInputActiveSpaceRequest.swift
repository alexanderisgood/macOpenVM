// SPDX-License-Identifier: Apache-2.0
import AppKit

/// Temporary window placement for an explicit capture request. This is never
/// input admission: AppKit must still report foreground/key/active-Space facts.
@MainActor final class GuestInputActiveSpaceRequest {
  @MainActor private final class Owner {
    weak var window: NSWindow?
    let identity: ObjectIdentifier
    let addedMove: Bool
    var requests: Set<UUID> = []

    init(_ window: NSWindow) {
      self.window = window
      identity = ObjectIdentifier(window)
      addedMove = !window.collectionBehavior.contains(.moveToActiveSpace)
    }
  }

  private static var owners: [ObjectIdentifier: Owner] = [:]
  private weak var window: NSWindow?
  private let token = UUID()
  private var owner: Owner?
  private var finished = false

  init(window: NSWindow) { self.window = window }

  /// Store the request with its session before beginning: this setter may
  /// synchronously invoke callbacks which cancel or replace the capture.
  @discardableResult func begin(allowMove: Bool = true) -> Bool {
    guard !finished, owner == nil, allowMove, let window,
      !window.styleMask.contains(.fullScreen),
      !window.collectionBehavior.contains(.canJoinAllSpaces)
    else { return false }
    Self.owners = Self.owners.filter { $0.value.window != nil }
    let identity = ObjectIdentifier(window)
    let record = Self.owners[identity] ?? Owner(window)
    owner = record
    record.requests.insert(token)
    Self.owners[identity] = record
    if !window.collectionBehavior.contains(.moveToActiveSpace) {
      window.collectionBehavior.insert(.moveToActiveSpace)
    }
    return !finished
  }

  /// Idempotent, including reentry from a native setter callback. An earlier
  /// request cannot restore this bit while a replacement still owns a lease.
  func finish() {
    guard !finished else { return }
    finished = true
    guard let record = owner else { return }
    owner = nil
    guard record.requests.remove(token) != nil, record.requests.isEmpty else { return }
    if Self.owners[record.identity] === record {
      Self.owners.removeValue(forKey: record.identity)
    }
    guard let window = record.window else { return }
    if record.addedMove, window.collectionBehavior.contains(.moveToActiveSpace) {
      window.collectionBehavior.remove(.moveToActiveSpace)
    }
  }
}
