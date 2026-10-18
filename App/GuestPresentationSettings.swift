// SPDX-License-Identifier: Apache-2.0
import VMCore

/// Live host presentation choices. These are independent of the VM's saved
/// graphics device, guest resolution and Windows display scaling settings.
struct GuestPresentationSettings: Equatable, Sendable {
  var scaling: GuestDisplayScaling = .fit
  var sharpeningEnabled = false
}
