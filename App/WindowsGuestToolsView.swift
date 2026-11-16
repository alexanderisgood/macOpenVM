// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import SwiftUI

struct WindowsGuestToolsButton: View {
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Button("Install Guest Tools…", systemImage: "shippingbox") {
      openWindow(id: "windows-guest-tools")
    }
  }
}

@MainActor struct WindowsGuestToolsView: View {
  @ObservedObject var session: DesktopSession
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Label("Guest Tools", systemImage: "shippingbox.fill")
          .font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
        Text("Set up your Windows drivers together.").font(.title3)
        if let configuration = session.configuration, session.usesWindowsDriverDisc {
          Text(configuration.name).font(.headline)
          VMContentCard("Included for this VM") {
            Label("Network connection", systemImage: "network")
            Label("Guest communication, when available", systemImage: "arrow.left.arrow.right")
            Label(
              session.guestToolsHasGraphics
                ? "Graphics driver" : "Basic display uses Windows' built-in driver",
              systemImage: "display")
            Text(
              "Keyboard, mouse and the current storage controller use Windows' built-in drivers."
            )
            .font(.callout).vmSupportingText()
            if !session.guestToolsHasGraphics {
              Button("Choose Accelerated Graphics…", action: session.showGraphicsSettings)
                .disabled(!session.canEditGraphicsSettings)
              Text(
                "Choose accelerated graphics while Windows is shut down, then prepare its matching tools below."
              )
              .font(.callout).vmSupportingText()
            }
          }
          VMContentCard("1. Prepare the installer") {
            if session.isActive {
              if session.guestToolsDiscIsSelected {
                Label("Tools disc is attached", systemImage: "checkmark.circle")
              } else {
                Text("Save your work and shut down Windows to attach the complete tools disc.")
                Button("Shut Down Windows") { session.perform(.stop) }
                  .disabled(session.state != .running)
              }
            } else {
              Button(
                session.preparing ? "Preparing…" : "Prepare Guest Tools",
                action: session.chooseSupportMedia
              ).vmGlassControl(prominent: true).disabled(!session.canPrepareGuestTools)
              if session.guestToolsDiscIsSelected {
                Label(
                  "Ready. Start Windows to open the installer.", systemImage: "checkmark.circle")
                Button("Start Windows") {
                  if session.startForGuestTools() { dismiss() }
                }.disabled(!session.canRequestStart)
              }
            }
            Text(
              "macOpenVM chooses the driver versions for your graphics settings. No downloads or folder selection are needed when tools are bundled."
            )
            .font(.callout).vmSupportingText()
            if let error = session.guestToolsPreparationError {
              Label(error, systemImage: "exclamationmark.triangle").font(.callout)
            }
          }
          VMContentCard("2. Open in Windows") {
            Text(
              "Choose Install macOpenVM Guest Tools from Windows AutoPlay. If no prompt appears, open File Explorer → This PC → macOpenVM Guest Tools, then double-click Install macOpenVM Tools."
            )
            if session.isActive, session.windowsDisplay?.canSelectDisplayConsole == true {
              Button("Show Windows for Setup") {
                session.showGuestToolsDisplay(.firmware)
                dismiss()
              }
            }
          }
          VMContentCard("3. Choose Install") {
            Text(
              "Approve the Windows administrator prompt once. The installer handles all matching drivers and shows which are working or need a restart."
            )
            Text(
              "An attached disc does not mean drivers are installed. Check the result in the Windows installer."
            )
            .font(.callout).vmSupportingText()
            if session.isActive, session.windowsDisplay?.canSelectDisplayConsole == true {
              Button("Show Windows GPU Display") {
                session.showGuestToolsDisplay(.gpu)
                dismiss()
              }
              Text(
                "Use this after the graphics driver reports Working. Restart Windows first if the installer requests it."
              )
              .font(.callout).vmSupportingText()
            }
          }
          if configuration.network == .disconnected {
            VMContentCard("Networking is disconnected") {
              Text(
                "Enable Shared networking in Machine → Networking Settings while Windows is shut down to give it a network adapter."
              )
            }
          }
        } else {
          Text(
            "Select a Windows VM to prepare its matching drivers. Linux normally supplies its device drivers through the guest operating system."
          )
        }
        WindowsSetupGuideButton()
      }
      .padding(24).frame(maxWidth: 660, alignment: .leading).frame(maxWidth: .infinity)
    }
    .frame(minWidth: 480, minHeight: 380)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}
