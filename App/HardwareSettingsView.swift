// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import SwiftUI

@MainActor struct HardwareSettingsView: View {
  @ObservedObject var session: DesktopSession
  let configuration: VMConfiguration
  @StateObject private var draft: HardwareSettingsDraft
  private let host = HostResources.current

  init(session: DesktopSession, configuration: VMConfiguration) {
    self.session = session
    self.configuration = configuration
    _draft = StateObject(wrappedValue: HardwareSettingsDraft(configuration: configuration))
  }

  var body: some View {
    VMGlassGroup {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Text("Hardware settings").font(.title.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
          Spacer()
          VMGlassBadge(title: "Experimental", symbol: "flask")
        }
        Text(configuration.name).font(.headline)
        Text("Changes take effect the next time you start this VM.")
          .font(.callout).vmSupportingText()
        VMOpenHistoryAdviceView(
          advice: session.hardwareOpenHistoryAdvice, dismiss: session.dismissOpenHistoryAdvice)
        VMContentCard {
          LabeledContent("Virtual CPUs") {
            TextField("Virtual CPUs", text: $draft.cpuCountText)
              .accessibilityLabel("Virtual CPUs").frame(width: 140)
          }
          LabeledContent("Memory (MiB)") {
            TextField("Memory (MiB)", text: $draft.memoryMiBText)
              .accessibilityLabel("Memory in MiB").frame(width: 140)
          }
          if let message = draft.numericError(host: host) {
            Label(message, systemImage: "exclamationmark.triangle")
              .font(.callout).fixedSize(horizontal: false, vertical: true)
              .accessibilityLabel("Hardware input error: \(message)")
          }
          Text(
            "1 GiB = 1,024 MiB. This Mac has \(host.cpuCount) CPUs and \(host.memoryBytes / 1_073_741_824) GiB of memory."
          )
          .font(.caption).vmSupportingText()
          Text("Leave at least two CPUs and half of the memory available to your Mac.")
            .font(.caption).vmSupportingText()
          if configuration.guest == .windows11 {
            Text("Windows requires at least 2 CPUs and 4,096 MiB of memory.")
              .font(.caption).vmSupportingText()
          }
        }
        if let message = session.hardwareError {
          Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Settings error: \(message)")
        }
        HStack {
          Button("Cancel") { session.editingHardware = false }
            .vmGlassControl().keyboardShortcut(.cancelAction)
          Spacer()
          if session.preparing {
            ProgressView().controlSize(.small).accessibilityLabel("Saving hardware settings")
          }
          Button("Save") { save() }
            .vmGlassControl(prominent: true).keyboardShortcut(.defaultAction)
            .disabled(draft.numericError(host: host) != nil)
        }
      }
      .padding(28).textFieldStyle(.roundedBorder)
      .disabled(session.preparing)
    }
    .frame(width: 570)
    .background(Color(nsColor: .windowBackgroundColor))
    .interactiveDismissDisabled(session.preparing)
  }

  private func save() {
    do {
      let prepared = try draft.prepared(host: host)
      session.saveHardware(cpuCount: prepared.cpuCount, memoryBytes: prepared.memoryBytes)
    } catch {
      session.hardwareError =
        (error as? VMError)?.errorDescription ?? "Review the VM hardware settings."
    }
  }
}
