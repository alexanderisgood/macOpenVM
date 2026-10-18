// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftUI

@MainActor struct DiskMetadataUpgradeView: View {
  @ObservedObject var session: DesktopSession
  let nonce: UUID
  let check: UUID
  var body: some View {
    VMGlassGroup {
      VStack(alignment: .leading, spacing: 18) {
        Text("Disk compatibility").font(.title.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        Text(session.diskCapacityConfiguration?.name ?? "Selected VM").font(.headline)
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            VMContentCard {
              if !session.diskMetadataSelectionIsCurrent(draft: nonce) {
                Text(
                  "The selected VM changed. Cancel and reopen Disk Capacity before checking again.")
              } else if let inspection = session.diskMetadataInspection {
                Text(DiskMetadataUpgradeCopy.message(inspection.status))
              } else if session.preparing {
                ProgressView("Working on compatibility…")
              } else {
                Text("Check again to inspect the VM’s current compatibility record.")
              }
            }
            Text(DiskMetadataUpgradeCopy.compatibility)
            Text(DiskMetadataUpgradeCopy.archive)
            if session.diskMetadataInspection?.eligibleAtCheck == true {
              Toggle(
                "I understand that older versions will no longer open this VM",
                isOn: Binding(
                  get: { session.diskMetadataAcknowledged },
                  set: { session.acknowledgeDiskMetadataUpgrade($0, draft: nonce, check: check) })
              )
              .disabled(!session.canRefreshDiskMetadataUpgrade)
            }
            if let message = session.diskMetadataMessage {
              Text(message).font(.callout)
            }
          }
          .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
          Button("Back") { session.leaveDiskMetadataUpgrade(draft: nonce, closeSheet: false) }
            .vmGlassControl()
          Button("Cancel") { session.leaveDiskMetadataUpgrade(draft: nonce, closeSheet: true) }
            .vmGlassControl().keyboardShortcut(.cancelAction)
          Spacer()
          Button("Check Again") { session.refreshDiskMetadataUpgrade(draft: nonce) }
            .vmGlassControl().disabled(!session.canRefreshDiskMetadataUpgrade)
          let inspectedVMID = session.diskMetadataInspection?.vmID
          let inspectedTransactionID = session.diskMetadataInspection?.transactionID
          Button("Upgrade Record") {
            if let vmID = inspectedVMID, let transaction = inspectedTransactionID {
              session.confirmDiskMetadataUpgrade(
                draft: nonce, check: check, inspectedVMID: vmID, transactionID: transaction)
            }
          }
          .vmGlassControl(prominent: true).disabled(!session.canConfirmDiskMetadataUpgrade)
        }
        .disabled(session.preparing)
      }
      .padding(28)
    }
    .frame(width: 620, height: 480).background(Color(nsColor: .windowBackgroundColor))
    .interactiveDismissDisabled(session.preparing)
  }
}
