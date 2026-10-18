// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// A local prerequisite check. Its action never selects a replacement runtime or starts a VM.
struct WindowsReadinessView: View {
  let readiness: WindowsLaunchReadiness
  let canRecheck: Bool
  let recheck: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 10) {
        if readiness.isChecking {
          ProgressView().controlSize(.small)
            .accessibilityLabel("Checking Windows startup requirements")
        } else {
          Image(systemName: readiness.symbol).accessibilityHidden(true)
        }
        Text(readiness.title).font(.callout.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 8)
        Button("Check Again", systemImage: "arrow.clockwise", action: recheck)
          .vmGlassControl()
          .disabled(!canRecheck || readiness.isChecking)
          .accessibilityLabel("Check Windows startup requirements again")
          .help("Recheck this app and its selected Windows runtime without starting the VM")
      }
      Text(readiness.message).font(.callout).vmSupportingText()
        .fixedSize(horizontal: false, vertical: true)
      Text("These checks do not start the VM, change its files or install Windows drivers.")
        .font(.caption).vmSupportingText()
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .contain)
  }
}
