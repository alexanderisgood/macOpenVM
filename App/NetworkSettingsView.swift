// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import SwiftUI

enum NetworkSettingsEligibility {
  static func allows(
    _ mode: NetworkMode, configuration: VMConfiguration,
    sharedPermission: SharedNetworkConfigurationPermission? = nil
  ) -> Bool {
    mode == .disconnected
      || configuration.guest == .linux && configuration.backend == .appleVz
      || sharedPermission?.allowsSharedConfiguration(configuration) == true
  }
}

@MainActor private final class NetworkSettingsDraft: ObservableObject {
  @Published var mode: NetworkMode

  init(configuration: VMConfiguration) {
    mode = configuration.network
  }
}

@MainActor struct NetworkSettingsView: View {
  @ObservedObject var session: DesktopSession
  let configuration: VMConfiguration
  let sharedPermission: SharedNetworkConfigurationPermission?
  @StateObject private var draft: NetworkSettingsDraft

  init(
    session: DesktopSession, configuration: VMConfiguration,
    sharedPermission: SharedNetworkConfigurationPermission? = nil
  ) {
    self.session = session
    self.configuration = configuration
    self.sharedPermission = sharedPermission
    _draft = StateObject(wrappedValue: NetworkSettingsDraft(configuration: configuration))
  }

  private var supportsShared: Bool {
    NetworkSettingsEligibility.allows(
      .shared, configuration: configuration, sharedPermission: sharedPermission)
  }

  var body: some View {
    VMGlassGroup {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Text("Networking settings").font(.title.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
          Spacer()
          VMGlassBadge(title: "Experimental", symbol: "flask")
        }
        Text(configuration.name).font(.headline)
        Text("Changes take effect the next time you start this VM.")
          .font(.callout).vmSupportingText()
        VMOpenHistoryAdviceView(
          advice: session.networkOpenHistoryAdvice, dismiss: session.dismissOpenHistoryAdvice)
        VMContentCard {
          Picker("Networking", selection: $draft.mode) {
            Text("Disconnected").tag(NetworkMode.disconnected)
            Text("Shared · Experimental").tag(NetworkMode.shared).disabled(!supportsShared)
          }
          .pickerStyle(.radioGroup)
          .accessibilityLabel("Networking mode")
          Text("Disconnected creates no virtual network interface for the guest.")
            .font(.callout).vmSupportingText()
          Text(
            "Shared networking grants the guest outbound access to your local network and the internet."
          )
          .font(.callout).vmSupportingText()
          if !supportsShared {
            Text("Shared networking requires native Linux or the reviewed Windows runtime.")
              .font(.callout).vmSupportingText()
          }
          if configuration.guest == .windows11 {
            Text(
              "Windows shared networking is experimental. Detailed network checks remain unverified."
            )
            .font(.callout).vmSupportingText()
            Text(
              "Use Attach Driver Disc, then choose Install driver and select drivers/netkvm in Windows when asked."
            )
            .font(.callout).vmSupportingText()
          }
        }
        if let message = session.networkError {
          Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Networking settings error: \(message)")
        }
        HStack {
          Button("Cancel") { session.editingNetwork = false }
            .vmGlassControl().keyboardShortcut(.cancelAction)
          Spacer()
          if session.preparing {
            ProgressView().controlSize(.small).accessibilityLabel("Saving networking settings")
          }
          Button("Save") { session.saveNetwork(mode: draft.mode) }
            .vmGlassControl(prominent: true).keyboardShortcut(.defaultAction)
            .disabled(
              !NetworkSettingsEligibility.allows(
                draft.mode, configuration: configuration, sharedPermission: sharedPermission))
        }
      }
      .padding(28)
      .disabled(session.preparing)
    }
    .frame(width: 610)
    .background(Color(nsColor: .windowBackgroundColor))
    .background(
      WindowAnchor(onWindow: {
        $0?.identifier = LibraryNetworkAppQualificationRequest.networkSheetIdentifier
      })
    )
    .interactiveDismissDisabled(session.preparing)
  }
}
