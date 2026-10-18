// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import SwiftUI

@MainActor private final class WindowsGraphicsSettingsEditor: ObservableObject {
  @Published var value: WindowsGraphicsSettingsDraft
  @Published var validationError: String?
  @Published var confirmingReset = false

  init(settings: WindowsGraphicsSettings) {
    value = WindowsGraphicsSettingsDraft(settings: settings)
  }
}

/// The owning session supplies stopped-state, selection and resource-admission guards.
@MainActor struct WindowsGraphicsSettingsView: View {
  let canUse120: Bool
  let isSaving: Bool
  let error: String?
  let preferenceWarning: String?
  let canResetRememberedSettings: Bool
  let resetRememberedSettings: () -> Void
  let save: (WindowsGraphicsSettings) -> Void
  let cancel: () -> Void
  @StateObject private var editor: WindowsGraphicsSettingsEditor

  init(
    settings: WindowsGraphicsSettings, canUse120: Bool, isSaving: Bool, error: String?,
    preferenceWarning: String? = nil, canResetRememberedSettings: Bool = false,
    resetRememberedSettings: @escaping () -> Void = {},
    save: @escaping (WindowsGraphicsSettings) -> Void, cancel: @escaping () -> Void
  ) {
    self.canUse120 = canUse120
    self.isSaving = isSaving
    self.error = error
    self.preferenceWarning = preferenceWarning
    self.canResetRememberedSettings = canResetRememberedSettings
    self.resetRememberedSettings = resetRememberedSettings
    self.save = save
    self.cancel = cancel
    _editor = StateObject(wrappedValue: WindowsGraphicsSettingsEditor(settings: settings))
  }

  var body: some View {
    VMGlassGroup {
      VStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
              Text("Windows graphics settings").font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
              Spacer(minLength: 0)
              VMGlassBadge(title: "Experimental", symbol: "flask")
            }
            Text(
              "Saving remembers these choices for this VM on this Mac and applies them to its next start. A moved or replacement VM starts with Basic display until you choose settings for its location. These settings are not written into the VM’s files."
            )
            .font(.callout).vmSupportingText()
            if let preferenceWarning {
              VMContentCard("Remembered settings") {
                Label(preferenceWarning, systemImage: "exclamationmark.triangle")
                  .fixedSize(horizontal: false, vertical: true)
                if canResetRememberedSettings {
                  Button("Reset Remembered Graphics Settings…") { editor.confirmingReset = true }
                    .vmGlassControl()
                    .accessibilityHint("Review resetting graphics choices for all VMs on this Mac")
                }
              }
              .font(.callout)
            }
            VMContentCard("Display") {
              Picker("Display mode", selection: $editor.value.settings.mode) {
                Text("Basic display").tag(WindowsGraphicsSettings.Mode.basic)
                Text("Accelerated graphics · Experimental")
                  .tag(WindowsGraphicsSettings.Mode.accelerated)
              }
              .pickerStyle(.radioGroup).accessibilityLabel("Windows display mode")
              .accessibilityIdentifier("windows-graphics-mode")
              if editor.value.settings.mode == .basic {
                Text("Basic display uses the ordinary Windows display path.")
                  .font(.callout).vmSupportingText()
              }
            }
            if editor.value.settings.mode == .accelerated {
              acceleratedSettings
              VMContentCard("Driver setup") {
                Text(
                  "This graphics option currently uses English (UK) keyboard mapping and experimental audio playback."
                )
                Text(
                  "The matching graphics driver disc is separate. Saving these settings does not attach a disc, install Windows drivers or verify driver health."
                )
                Text(
                  "Use the supplied driver disc and check the active display device in Windows. View → Display → Firmware Display remains available for recovery."
                )
              }
              .font(.callout).vmSupportingText()
            }
            if let message = editor.validationError ?? error {
              Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Graphics settings error: \(message)")
            }
          }
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(28)
        }
        Divider()
        HStack(spacing: 12) {
          Button("Cancel", action: cancel).vmGlassControl().keyboardShortcut(.cancelAction)
          Spacer()
          if isSaving {
            ProgressView().controlSize(.small).accessibilityLabel("Checking graphics settings")
          }
          Button("Save Settings", action: commit)
            .vmGlassControl(prominent: true).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
      }
      .disabled(isSaving)
    }
    .frame(
      minWidth: 610, idealWidth: 650, maxWidth: 760,
      minHeight: 460, idealHeight: 640, maxHeight: 760
    )
    .background(Color(nsColor: .windowBackgroundColor))
    .interactiveDismissDisabled(isSaving)
    .onChange(of: editor.value) { _, _ in editor.validationError = nil }
    .confirmationDialog(
      "Reset remembered graphics settings?", isPresented: $editor.confirmingReset,
      titleVisibility: .visible
    ) {
      Button("Reset All Remembered Settings", role: .destructive) {
        guard canResetRememberedSettings, !isSaving else { return }
        resetRememberedSettings()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Removes the graphics choices remembered on this Mac for all VMs. Your VM files and Windows drivers are kept. Save separately to apply the choices entered here."
      )
    }
  }

  private var acceleratedSettings: some View {
    VMContentCard("Initial display") {
      LabeledContent("Initial width (pixels)") {
        TextField("Initial width", text: $editor.value.widthText)
          .frame(width: 140).accessibilityLabel("Initial display width in pixels")
      }
      LabeledContent("Initial height (pixels)") {
        TextField("Initial height", text: $editor.value.heightText)
          .frame(width: 140).accessibilityLabel("Initial display height in pixels")
      }
      Text(
        "Enter whole pixel counts without separators. Width: 320–8,192; height: 200–8,192; maximum total: 16,777,216 pixels."
      )
      .font(.caption).vmSupportingText()
      Text(
        "This is the size requested at startup. After Windows starts, use View → Match Mac Resolution to request the current guest viewport size. Check the applied mode in Windows."
      )
      .font(.callout).vmSupportingText()
      Divider()
      Picker("Requested refresh rate", selection: $editor.value.settings.refreshRate) {
        Text("60 Hz").tag(WindowsGraphicsSettings.RefreshRate.hz60)
        Text("120 Hz · Experimental").tag(WindowsGraphicsSettings.RefreshRate.hz120)
          .disabled(!canUse120)
      }
      .pickerStyle(.radioGroup).accessibilityLabel("Requested display refresh rate")
      if !canUse120 {
        Text(
          "120 Hz requires a Mac display that reports support for 120 Hz. Move the VM window to that display before saving and starting, or choose 60 Hz."
        )
        .font(.caption).vmSupportingText()
      }
      Text(
        "The requested refresh rate does not confirm Windows’ applied mode or frame delivery. A 120 Hz mode does not promise 120 frames per second."
      )
      .font(.caption).vmSupportingText()
    }
  }

  private func commit() {
    do {
      let settings = try editor.value.prepared(canUse120: canUse120)
      editor.validationError = nil
      save(settings)
    } catch {
      editor.validationError =
        (error as? VMError)?.errorDescription ?? "Review the graphics settings."
    }
  }
}
