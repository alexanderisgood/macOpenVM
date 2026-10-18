// SPDX-License-Identifier: Apache-2.0
import Foundation
import Qemu

/// Local callback correlation only. These values grant no source authority,
/// negotiation, FD admission or permission to acknowledge a producer snapshot.
struct HDRPresentationCallbackGate: Sendable {
  struct Owner: Equatable, Sendable {
    let controllerID: UUID
    let inputConnectionEpoch: UUID
    let transportConnectionEpoch: UUID

    /// A standalone renderer has fresh local ownership. The App controller
    /// supplies its actual input/transport epochs instead of these defaults.
    init(
      controllerID: UUID = UUID(), inputConnectionEpoch: UUID = UUID(),
      transportConnectionEpoch: UUID = UUID()
    ) {
      self.controllerID = controllerID
      self.inputConnectionEpoch = inputConnectionEpoch
      self.transportConnectionEpoch = transportConnectionEpoch
    }
  }
  struct Ticket: Sendable {
    fileprivate let owner: Owner
    fileprivate let activation: UUID
    fileprivate let message: HDRFrameMessage
  }

  let owner: Owner
  private let surface: HDRFrameSurfaceToken
  private var activation = UUID()
  private var active = false
  private var retired = false

  init(first: HDRFrameMessage, owner: Owner) {
    surface = first.surfaceToken
    self.owner = owner
  }

  mutating func setActive(_ next: Bool) {
    guard !retired, next != active else { return }
    active = next
    activation = UUID()
  }

  mutating func retire() {
    retired = true
    active = false
    activation = UUID()
  }

  func ticket(for message: HDRFrameMessage) -> Ticket? {
    guard !retired, active, message.surfaceToken == surface else { return nil }
    return Ticket(owner: owner, activation: activation, message: message)
  }

  func accepts(_ ticket: Ticket, message: HDRFrameMessage, currentOwner: Owner) -> Bool {
    !retired && active && currentOwner == owner && ticket.owner == owner
      && ticket.activation == activation && ticket.message == message
      && message.surfaceToken == surface
  }
}
