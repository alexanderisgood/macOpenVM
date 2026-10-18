// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import SwiftUI

/// Only working Linux/EFI controls are exposed; Windows remains a separately gated path.
@MainActor struct LinuxCreationView: View {
  @ObservedObject var session: DesktopSession
  private let nonce: UUID
  @StateObject private var draft: LinuxCreationDraft
  @StateObject private var capacity = CreationStorageAdvisor()
  private let host = HostResources.current

  init(session: DesktopSession) {
    self.session = session
    nonce = session.creationDraftNonce
    _draft = StateObject(wrappedValue: LinuxCreationDraft(host: .current))
  }

  var body: some View {
    VMGlassGroup {
      VStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
              VStack(alignment: .leading, spacing: 8) {
                Text("New Linux VM").font(.largeTitle.weight(.semibold))
                  .accessibilityAddTraits(.isHeader)
                Text("Choose an image, a home for the VM and its hardware.")
                  .font(.callout).vmSupportingText()
              }
              Spacer(minLength: 0)
              VMGlassBadge(title: "Experimental", symbol: "flask")
            }
            VMContentCard("Name") {
              TextField("VM name", text: $draft.name)
                .accessibilityLabel("VM name")
            }
            VMContentCard("Installation") {
              HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                  Text("ARM64 Linux image").font(.callout.weight(.medium))
                  Text(draft.media?.lastPathComponent ?? "Select your installation image")
                    .font(.callout).vmSupportingText()
                    .lineLimit(2).truncationMode(.middle)
                    .help(draft.media?.path ?? "Choose a lawfully obtained ARM64 Linux ISO")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose ARM64 ISO…", systemImage: "opticaldisc") {
                  session.chooseCreationDraftLocation(folder: false, nonce: nonce) {
                    draft.media = $0
                  }
                }.vmGlassControl()
              }
              Divider()
              HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                  Text("Destination").font(.callout.weight(.medium))
                  Text(draft.parent?.path ?? "Select a folder for the new VM")
                    .font(.callout).vmSupportingText()
                    .lineLimit(2).truncationMode(.middle)
                    .help(draft.parent?.path ?? "Choose the parent folder for a new VM")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose destination…", systemImage: "folder") {
                  session.chooseCreationDraftLocation(folder: true, nonce: nonce) {
                    draft.parent = $0
                  }
                }.vmGlassControl()
              }
              Text("Use an ARM64 Linux installation image with EFI boot support.")
                .font(.caption).vmSupportingText()
            }
            VMContentCard("Hardware") {
              LabeledContent("Virtual CPUs") {
                TextField("CPUs", text: $draft.cpuCountText)
                  .accessibilityLabel("Virtual CPUs").frame(width: 140)
              }
              LabeledContent("Memory (GiB)") {
                TextField("Memory (GiB)", text: $draft.memoryGiBText)
                  .accessibilityLabel("Memory in GiB").frame(width: 140)
              }
              LabeledContent("Disk capacity (GiB)") {
                TextField("Disk capacity (GiB)", text: $draft.diskGiBText)
                  .accessibilityLabel("Disk capacity in GiB").frame(width: 140)
              }
              if let message = draft.numericError(host: host) {
                Label(message, systemImage: "exclamationmark.triangle")
                  .font(.callout).fixedSize(horizontal: false, vertical: true)
                  .accessibilityLabel("Hardware input error: \(message)")
              }
              // Zero suppresses only the growth advisory; preparation parses the raw text again.
              CreationStorageCapacityView(
                advisor: capacity, parent: draft.parent, diskGiB: draft.parsedDiskGiB ?? 0)
              Text(
                "This Mac has \(host.cpuCount) CPUs and \(host.memoryBytes / 1_073_741_824) GiB RAM. Allocation must leave host capacity and use at most half of host RAM."
              )
              .font(.caption).vmSupportingText()
            }
            VMContentCard("Networking") {
              Toggle("Enable shared networking (experimental)", isOn: $draft.sharedNetwork)
                .toggleStyle(.switch)
                .accessibilityLabel("Enable shared networking, experimental")
              Text(
                "Networking is disconnected by default. Shared networking permits guest outbound access."
              )
              .font(.caption).vmSupportingText()
            }
            Text(
              "Creation preserves existing VMs. An interrupted creation retains its new folder for inspection."
            )
            .font(.caption).vmSupportingText()
          }
          .textFieldStyle(.roundedBorder).controlSize(.large)
          .frame(maxWidth: 740, alignment: .leading)
          .padding(28)
          .frame(maxWidth: .infinity)
        }
        Divider()
        HStack(spacing: 12) {
          Button("Cancel") { session.cancelCreation(nonce: nonce) }
            .vmGlassControl().keyboardShortcut(.cancelAction)
          Spacer()
          if session.preparing {
            ProgressView().controlSize(.small).accessibilityLabel("Preparing the new VM")
          }
          Button("Create VM", systemImage: "plus") { create() }
            .vmGlassControl(prominent: true).keyboardShortcut(.return)
            .disabled(
              draft.numericError(host: host) != nil
                || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || draft.media == nil
                || draft.parent == nil || !capacity.canCreate(in: draft.parent))
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .disabled(session.preparing)
  }

  private func create() {
    guard session.creationDraftIsAvailable(nonce: nonce), capacity.canCreate(in: draft.parent)
    else { return }
    do {
      let prepared = try draft.prepared(host: host)
      session.createVM(prepared.configuration, in: prepared.destination, nonce: nonce)
    } catch {
      session.reportCreationError(
        (error as? VMError)?.errorDescription ?? "Review the Linux VM settings.", nonce: nonce)
    }
  }
}
