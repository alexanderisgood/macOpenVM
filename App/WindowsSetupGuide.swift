// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import SwiftUI

struct WindowsSetupGuideButton: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Windows Setup & Drivers…", systemImage: "questionmark.circle") {
      openWindow(id: "windows-setup")
    }
  }
}

/// Read-only help stays available beside the running guest. Attachment and
/// networking still go through the selected VM's existing stopped controls.
@MainActor struct WindowsSetupGuide: View {
  @ObservedObject var session: DesktopSession

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Windows Setup & Drivers").font(.largeTitle.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        Text("Use your Windows 11 ARM64 ISO. Guest Tools supplies the matching drivers separately.")
          .font(.callout).vmSupportingText()
        VMContentCard("Install all matching drivers") {
          WindowsGuestToolsButton()
          Text(
            "Prepare Guest Tools, start Windows, then open Install macOpenVM Tools on its disc. Choose Install once to set up networking, guest communication when available, and the graphics driver for this VM."
          )
          Text(
            "If graphics says Not detected, setup is incomplete. Choose Restart in Windows, then retry. The steps below help when Windows Setup needs networking before you reach the desktop."
          )
          .font(.callout).vmSupportingText()
        }
        VMContentCard("Keep storage efficient") {
          Text(
            "New VMs use a sparse disk: the capacity limit is not space reserved on your Mac. CPU and memory start with recommendations for your Mac."
          )
          Text(
            "In Guest Tools, leave Save disk space selected to turn off Windows hibernation and Fast Startup and reclaim unused blocks. This preserves paging, Windows Recovery and your files. Use Storage settings in the installer to inspect Windows disk usage."
          )
          .font(.callout).vmSupportingText()
        }
        if let configuration = session.configuration, session.usesWindowsDriverDisc {
          VMContentCard("Selected VM: \(configuration.name)") {
            LabeledContent("Networking") {
              Text(configuration.network == .shared ? "Shared" : "Disconnected — no adapter")
            }
            LabeledContent("Driver disc") {
              Text(configuration.supportMedia == nil ? "Not attached" : "Attached")
            }
            Text(
              "These are the saved settings. Windows driver installation and internet access must be checked inside Windows."
            )
            .font(.caption).vmSupportingText()
          }
        }
        VMContentCard("1. Enable the network adapter") {
          Text("Stop the VM. Choose Machine → Networking Settings, select Shared, then Save.")
          Text(
            "Shared networking lets Windows use your local network and internet connection. Disconnected removes the adapter, so a driver alone cannot get Windows online."
          )
          .font(.callout).vmSupportingText()
        }
        VMContentCard("2. Attach the driver disc") {
          Text(
            "While the VM is stopped, choose Machine → Install Guest Tools → Prepare Guest Tools. Then start Windows."
          )
          Text(
            "The app selects the matching disc when it is available. You do not need to find a folder on your Mac."
          )
          .font(.callout).vmSupportingText()
        }
        VMContentCard("3. Install the network driver in Windows") {
          Text(
            "At “Let’s connect you to a network”, choose Install driver. Browse to the driver disc, open drivers → netkvm, and select that folder."
          )
          Text(
            "The drive letter can vary. Keep any “Include subfolders” option selected. After Windows installs the driver, wait for a connection and choose Next."
          )
          .font(.callout).vmSupportingText()
          Text(
            "This provides a virtual Ethernet connection; you do not choose your Mac’s Wi-Fi network inside Windows."
          )
          .font(.callout).vmSupportingText()
        }
        VMContentCard("Get drivers or more help") {
          if let url = URL(
            string:
              "https://github.com/alexanderisgood/macOpenVM/releases/tag/windows-arm64-virtio-0.1.302-1"
          ) {
            Link("Download ARM64 drivers", destination: url)
          }
          Text(
            "The driver preview includes NetKVM networking, VirtIO serial and basic VirtIO display drivers, with licenses and checksums. Install only drivers for devices your VM provides."
          )
          .font(.callout).vmSupportingText()
          Text(
            "The download is a ZIP, not an attachable disc. If the app cannot find its driver disc or Windows runtime, see the setup guide. Public source builds do not yet supply a complete Windows runtime."
          )
          .font(.callout).vmSupportingText()
          if let url = URL(
            string: "https://github.com/alexanderisgood/macOpenVM/blob/main/docs/windows-setup.md")
          {
            Link("Open the Windows setup guide", destination: url)
          }
        }
      }
      .textSelection(.enabled)
      .padding(24)
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .frame(minWidth: 480, minHeight: 360)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}
