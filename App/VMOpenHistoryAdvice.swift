// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import SwiftUI
import VMCore

/// Point-in-time read-only advice, never runtime ownership or recovery authority.
struct VMOpenHistoryAdvice: Identifiable, Equatable {
  let id = UUID()
  let configuration: VMConfiguration
  let configurationURL: URL
  let history: RuntimeHistoryStatus
  let message: String

  init?(configuration: VMConfiguration, at url: URL, history: RuntimeHistoryStatus) {
    let detail: String
    switch history {
    case .interruptedOrUnreconciled: detail = "no recorded normal shutdown"
    case .forcedStopRecorded: detail = "been force-stopped"
    case .failureRecorded: detail = "failed"
    default: return nil
    }
    self.configuration = configuration
    configurationURL = url
    self.history = history
    message =
      "When this VM was opened, its previous run had \(detail). Use the guest’s recovery options if it has trouble starting."
  }
}

/// Shared nonmodal presentation in the selected workspace and its settings editors.
@MainActor struct VMOpenHistoryAdviceView: View {
  let advice: VMOpenHistoryAdvice?
  let dismiss: (UUID) -> Void

  var body: some View {
    if let advice {
      VMContentCard {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 6) {
            Text("Previous run").font(.headline)
            Text(advice.message).font(.callout)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
          Button("Dismiss") { dismiss(advice.id) }
            .vmGlassControl().accessibilityLabel("Dismiss previous run notice")
        }
      }
    }
  }
}
