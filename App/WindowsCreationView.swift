// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Qemu
import SwiftUI

/// Source-qualified creation surface. Its entry is enabled only by the reviewed ordinary lane.
@MainActor struct WindowsCreationView: View {
  @ObservedObject var session: DesktopSession
  private let nonce: UUID
  @StateObject private var draft: WindowsCreationDraft
  @StateObject private var capacity = CreationStorageAdvisor()
  private let resources: ReviewedQemuCreationResources
  private let host = HostResources.current

  init(session: DesktopSession, resources: ReviewedQemuCreationResources) {
    self.session = session
    nonce = session.creationDraftNonce
    self.resources = resources
    _draft = StateObject(wrappedValue: WindowsCreationDraft())
  }

  var body: some View {
    VMGlassGroup {
      VStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
              VStack(alignment: .leading, spacing: 8) {
                Text("New Windows VM").font(.largeTitle.weight(.semibold))
                  .accessibilityAddTraits(.isHeader)
                Text("Choose an image, a home for the VM and its hardware.")
                  .font(.callout).vmSupportingText()
              }
              Spacer(minLength: 0)
              VMGlassBadge(title: "Experimental", symbol: "flask")
            }
            VMContentCard("Name") {
              TextField("VM name", text: $draft.name).accessibilityLabel("VM name")
            }
            VMContentCard("Installation") {
              HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                  Text("Windows 11 ARM64 image").font(.callout.weight(.medium))
                  Text(draft.media?.lastPathComponent ?? "Select your installation image")
                    .font(.callout).vmSupportingText().lineLimit(2).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose ARM64 ISO…", systemImage: "opticaldisc") {
                  session.chooseCreationDraftLocation(
                    folder: false, title: "Choose your ARM64 Windows ISO", nonce: nonce
                  ) { draft.media = $0 }
                }.vmGlassControl()
              }
              Divider()
              HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                  Text("Destination").font(.callout.weight(.medium))
                  Text(draft.parent?.path ?? "Select a folder for the new VM")
                    .font(.callout).vmSupportingText().lineLimit(2).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose destination…", systemImage: "folder") {
                  session.chooseCreationDraftLocation(folder: true, nonce: nonce) {
                    draft.parent = $0
                  }
                }.vmGlassControl()
              }
              Text("Use a Windows 11 ARM64 installation image with EFI boot support.")
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
              Text("Windows needs at least 2 virtual CPUs, 4 GiB memory and a 64 GiB disk.")
                .font(.caption).vmSupportingText()
              if let message = draft.numericError(host: host) {
                Label(message, systemImage: "exclamationmark.triangle")
                  .font(.callout).fixedSize(horizontal: false, vertical: true)
                  .accessibilityLabel("Hardware input error: \(message)")
              }
              // Zero suppresses only the growth advisory; preparation parses the raw text again.
              CreationStorageCapacityView(
                advisor: capacity, parent: draft.parent, diskGiB: draft.parsedDiskGiB ?? 0)
            }
            VMContentCard("Networking") {
              Text("The new VM starts disconnected.").font(.callout)
            }
            Text(
              "Creation preserves existing VMs. An interrupted creation retains its new folder for inspection."
            )
            .font(.caption).vmSupportingText()
          }
          .textFieldStyle(.roundedBorder).controlSize(.large)
          .frame(maxWidth: 740, alignment: .leading).padding(28)
          .frame(maxWidth: .infinity)
        }
        Divider()
        HStack(spacing: 12) {
          Button("Cancel") { session.cancelCreation(nonce: nonce) }.vmGlassControl()
            .keyboardShortcut(
              .cancelAction)
          Spacer()
          if session.preparing {
            ProgressView().controlSize(.small).accessibilityLabel("Preparing the new VM")
          }
          Button("Create VM", systemImage: "plus") { create() }
            .vmGlassControl(prominent: true).keyboardShortcut(.return)
            .disabled(
              draft.numericError(host: host) != nil
                || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || draft.media == nil || draft.parent == nil
                || !capacity.canCreate(in: draft.parent))
        }.padding(.horizontal, 28).padding(.vertical, 18)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor)).disabled(session.preparing)
  }

  private func create() {
    guard session.creationDraftIsAvailable(nonce: nonce), capacity.canCreate(in: draft.parent)
    else { return }
    do {
      let prepared = try draft.prepared(host: host)
      session.createWindowsVM(
        prepared.configuration, in: prepared.destination, resources: resources, nonce: nonce)
    } catch {
      session.reportCreationError(
        (error as? VMError)?.errorDescription ?? "Review the Windows VM settings.", nonce: nonce)
    }
  }
}
