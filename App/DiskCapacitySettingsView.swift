// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import SwiftUI

@MainActor struct DiskCapacitySettingsView: View {
  @ObservedObject var session: DesktopSession
  let configuration: VMConfiguration
  private let nonce: UUID
  @StateObject private var draft: DiskCapacityDraft

  init(session: DesktopSession, configuration: VMConfiguration) {
    self.session = session
    self.configuration = configuration
    nonce = session.diskCapacityDraftNonce
    _draft = StateObject(wrappedValue: DiskCapacityDraft(configuration: configuration))
  }

  var body: some View {
    VMGlassGroup {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Text("Disk capacity").font(.title.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
          Spacer()
          VMGlassBadge(title: "Experimental", symbol: "flask")
        }
        Text(configuration.name).font(.headline)
        VMContentCard {
          LabeledContent("Current capacity", value: draft.currentCapacityDescription)
          LabeledContent("New capacity (GiB)") {
            TextField("New capacity (GiB)", text: $draft.capacityGiBText)
              .accessibilityLabel("New disk capacity in GiB").frame(width: 140)
          }
          if let message = draft.inputError {
            Label(message, systemImage: "exclamationmark.triangle")
              .font(.callout).fixedSize(horizontal: false, vertical: true)
          }
          Text("1 GiB = 1,024 MiB. Choose a larger capacity, up to 2,048 GiB.")
            .font(.caption).vmSupportingText()
        }
        Text(
          "Keep a backup before expanding the disk. This adds empty space to the virtual disk; expand the partition inside Windows or Linux afterwards. Disk capacity cannot be reduced here."
        )
        .font(.callout).fixedSize(horizontal: false, vertical: true)
        if let message = session.diskCapacityError {
          Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        Button("Disk compatibility…") { session.showDiskMetadataUpgrade(draft: nonce) }
          .vmGlassControl().disabled(!session.canInspectDiskMetadata)
          .help("Check whether an older completed disk expansion can use a newer record.")
        HStack {
          Button("Cancel") { session.cancelDiskCapacitySettings(draft: nonce) }
            .vmGlassControl().keyboardShortcut(.cancelAction)
          Spacer()
          if session.preparing {
            ProgressView().controlSize(.small).accessibilityLabel("Expanding the virtual disk")
          }
          Button("Expand Disk…") { draft.confirmationTarget = try? draft.prepared() }
            .vmGlassControl(prominent: true).keyboardShortcut(.defaultAction)
            .disabled(draft.inputError != nil || !session.canSaveDiskCapacity)
        }
      }
      .padding(28).textFieldStyle(.roundedBorder).disabled(session.preparing)
    }
    .frame(width: 570).background(Color(nsColor: .windowBackgroundColor))
    .interactiveDismissDisabled(session.preparing)
    .confirmationDialog(
      "Expand this VM’s disk?",
      isPresented: Binding(
        get: { draft.confirmationTarget != nil }, set: { if !$0 { draft.confirmationTarget = nil } }
      ), titleVisibility: .visible
    ) {
      if let target = draft.confirmationTarget {
        Button("Expand to \(target / 1_073_741_824) GiB") {
          draft.confirmationTarget = nil
          session.saveDiskCapacity(targetBytes: target, draft: nonce)
        }
      }
      Button("Cancel", role: .cancel) { draft.confirmationTarget = nil }
    } message: {
      Text(
        "Existing data stays in place. The guest partition needs a separate expansion afterwards.")
    }
  }
}
