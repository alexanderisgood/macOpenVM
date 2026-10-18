// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import VMCore

/// Observe the active display itself. DesktopSession publishes its replacement,
/// but frame availability, capture and resize completion belong to this object.
@MainActor struct WindowsGuestCommands: Commands {
  @ObservedObject var display: RfbLabSession
  @ObservedObject var session: DesktopSession

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      if let frame = display.frame {
        Text("Windows Display: \(frame.size.width) × \(frame.size.height)")
      }
      Menu("Display Scaling") {
        Picker("Display Scaling", selection: $display.presentationSettings.scaling) {
          Text("Fit to Window").tag(GuestDisplayScaling.fit)
          Text("Integer Pixels").tag(GuestDisplayScaling.integer)
        }.pickerStyle(.inline)
      }
      .disabled(display.frame == nil)
      .help(
        "Integer Pixels uses whole pixel multiples with letterboxing. Smaller windows fit the whole display normally."
      )
      Toggle("Light Sharpening", isOn: $display.presentationSettings.sharpeningEnabled)
        .disabled(!display.canSharpenPresentation)
        .help(
          "Lightly sharpen enlarged Windows graphics. Native-size and smaller images remain unchanged."
        )
      if display.canMatchMacResolution {
        if let pixels = display.desiredNativePixels {
          Text("Mac Viewport: \(pixels.width) × \(pixels.height)")
        }
        Button("Match Mac Resolution", action: display.matchMacResolution)
          .disabled(
            display.desiredNativePixels == nil || display.frame == nil
              || display.resizePending || display.consoleSwitchPending)
      }
      if let error = display.consoleError {
        Text(error)
      }
      if display.canSelectDisplayConsole {
        if let visible = display.fullscreenMenuBarVisible {
          Text(visible ? "macOS Menu Bar: Visible" : "macOS Menu Bar: Hidden")
        }
        if let flags = display.fullscreenPresentationFlags { Text(flags) }
        Menu("Display") {
          ForEach(WindowsDisplayConsole.allCases) { console in
            Button(console.title) { display.selectDisplayConsole(console) }
          }
        }.disabled(
          display.consoleSwitchPending || display.resizePending || !display.displayConnected)
        Button(
          display.displayTimingRunning ? "Measuring Display Delivery…" : "Measure Display Delivery",
          action: display.measureDisplayDelivery
        ).disabled(display.displayTimingRunning || display.frame == nil)
        Button("Copy Display Measurement", action: display.copyDisplayMeasurement)
          .disabled(!display.canCopyDisplayMeasurement)
        if let result = display.displayTimingResult {
          Text(
            String(format: "Received %.1f/s · Drawn %.1f/s", result.receiveRate, result.drawRate))
          Text(
            String(
              format: "Draw gaps: median %.2f ms · p95 %.2f ms · worst %.2f ms",
              result.drawGaps.medianMS, result.drawGaps.p95MS, result.drawGaps.longestMS))
          Text(
            String(
              format: "Receive to draw: median %.2f ms · p95 %.2f ms",
              result.receiveToDraw.medianMS, result.receiveToDraw.p95MS))
          Text("20 seconds · \(display.displayTimingMethod) · Physical scanout unmeasured")
          if let rate = result.presentationRate, let gaps = result.presentationGaps {
            Text(String(format: "Mac presentations %.1f/s", rate))
            Text(
              String(
                format: "Presentation gaps: median %.2f ms · p95 %.2f ms · worst %.2f ms",
                gaps.medianMS, gaps.p95MS, gaps.longestMS))
          }
        }
        if let error = display.displayTimingError { Text(error) }
      }
      Button("Reconnect Display") { Task { await display.connectDisplay() } }
        .keyboardShortcut("r", modifiers: [.command, .shift])
      Button("Show VM Library", action: session.showLibrary)
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(!session.canShowLibrary)
    }
    CommandMenu("Input") {
      Text(display.captured ? "Input Captured" : "Input Released")
      // A live frame hides the display footer. Keep capture progress/refusals
      // visible here until input has actually been captured.
      if display.frame != nil, !display.captured { Text(display.message) }
      if let error = display.inputBacklogError { Text(error) }
      Button(
        display.relativeMouse ? "Release Game Mouse" : "Release Input", action: session.releaseInput
      )
      .keyboardShortcut(.escape, modifiers: [.control, .option])
      Button("Capture Input", action: session.captureInput)
        .disabled(
          !session.isActive || !display.canCaptureInput
            || display.resizePending || display.consoleSwitchPending)
      Toggle("Use Windows Cursor", isOn: $display.useGuestCursor)
        .disabled(!display.canChooseGuestCursor)
      Divider()
      if display.relativeMouse { Text("Control–Option–Escape returns the mouse to macOS") }
      Button(display.relativeMouse ? "Game Mouse ✓" : "Game Mouse") {
        display.setRelativeMouse(true)
      }
      .disabled(!display.canChangeMouseMode)
      Button(display.relativeMouse ? "Desktop Mouse" : "Desktop Mouse ✓") {
        display.setRelativeMouse(false)
      }
      .disabled(!display.canChangeMouseMode)
      if let error = display.mouseModeError { Text(error) }
    }
  }
}
