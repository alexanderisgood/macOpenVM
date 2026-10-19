// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import SwiftUI

/// The home screen observes the saved list directly; showing it never selects or starts a VM.
struct SavedVMLibrarySummary: View {
  @ObservedObject var library: VMLibrary
  let canOpen: Bool
  let open: () -> Void

  var body: some View {
    if !library.entries.isEmpty || library.errorMessage != nil {
      VMContentCard {
        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Saved virtual machines").font(.headline).accessibilityAddTraits(.isHeader)
            Text(summary).font(.caption).vmSupportingText()
          }
          Spacer(minLength: 0)
          Button("Browse Library", systemImage: "square.stack", action: open)
            .vmGlassControl().disabled(!canOpen)
            .help("Choose a saved VM without starting it")
        }
        if !library.entries.isEmpty {
          Text(preview).font(.callout).vmSupportingText().lineLimit(2)
        }
        if let error = library.errorMessage {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var summary: String {
    if library.entries.isEmpty { return "Saved list unavailable" }
    return library.entries.count == 1 ? "1 saved VM" : "\(library.entries.count) saved VMs"
  }

  private var preview: String {
    let names = library.entries.prefix(3).map(\.name).joined(separator: " · ")
    let remaining = library.entries.count - 3
    return remaining > 0 ? "\(names) · \(remaining) more" : names
  }
}

struct VMLibraryView: View {
  @ObservedObject var session: DesktopSession
  @ObservedObject var library: VMLibrary
  @FocusState private var searchFocused: Bool

  private var matchingCount: Int {
    library.matching(.windows11).count + library.matching(.linux).count
  }

  var body: some View {
    VMGlassGroup {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Text("Your virtual machines").font(.title.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
          Spacer()
          Button("Done") { session.showingLibrary = false }
            .vmGlassControl().keyboardShortcut(.cancelAction)
        }
        HStack(spacing: 12) {
          Menu {
            Button("Windows VM…") { session.requestLibraryNavigation(.newWindows) }
              .accessibilityLabel("Create a Windows 11 ARM64 VM")
            Button("Linux VM…") { session.requestLibraryNavigation(.newLinux) }
              .accessibilityLabel("Create an ARM64 Linux VM")
          } label: {
            Label("New VM", systemImage: "plus")
          }
          .menuStyle(.button).vmGlassControl().fixedSize()
          Button("Open VM…", systemImage: "folder") {
            session.requestLibraryNavigation(.open)
          }
          .vmGlassControl()
        }
        .disabled(!session.canRequestLibraryNavigation)
        HStack {
          Image(systemName: "magnifyingglass").accessibilityHidden(true)
          TextField("Search saved VMs", text: $library.query)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Search saved virtual machines")
            .accessibilityIdentifier("vm-library-search")
            .focused($searchFocused)
          if !library.query.isEmpty {
            Button("Clear Search", systemImage: "xmark.circle.fill", action: clearSearch)
              .labelStyle(.iconOnly).buttonStyle(.borderless)
              .accessibilityLabel("Clear search").help("Show all saved VMs")
          }
        }
        Text(resultSummary).font(.caption).vmSupportingText()
        if let error = library.errorMessage, !library.entries.isEmpty {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Library error: \(error)")
        }
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            group(.windows11, title: "Windows 11 ARM64")
            group(.linux, title: "Linux ARM64")
            if let empty = VMLibraryPresentation.emptyState(
              savedCount: library.entries.count, matchingCount: matchingCount,
              hasLibraryError: library.errorMessage != nil)
            {
              emptyState(empty)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        footer
      }.padding(24)
    }
    .frame(
      minWidth: 610, idealWidth: 680, maxWidth: 800,
      minHeight: 520, idealHeight: 600, maxHeight: 760
    )
    .background(Color(nsColor: .windowBackgroundColor))
    .background(WindowAnchor(onWindow: session.registerLibraryWindow))
    .onAppear { searchFocused = true }
  }

  @ViewBuilder private var footer: some View {
    VStack(alignment: .leading, spacing: 6) {
      if session.needsOwnershipRecovery {
        Text(
          "The current VM needs recovery. Close the library to review its status and preserve its files."
        )
      } else if session.isBusy {
        Text("Close the library to return to the current VM or wait for its operation to finish.")
      } else {
        Text("Open a VM, then choose Start. Settings and library options are in Actions.")
      }
    }
    .font(.caption).vmSupportingText()
  }

  private var resultSummary: String {
    if library.entries.isEmpty, library.errorMessage != nil {
      return "Saved list unavailable"
    }
    if VMLibraryPresentation.hasSearch(library.query) {
      return "\(matchingCount) of \(library.entries.count) saved VMs"
    }
    return library.entries.count == 1 ? "1 saved VM" : "\(library.entries.count) saved VMs"
  }

  private func emptyState(_ state: VMLibraryPresentation.EmptyState) -> some View {
    VMContentCard {
      Text(state.title).font(.headline).accessibilityAddTraits(.isHeader)
      if state == .unavailable, let error = library.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.callout).fixedSize(horizontal: false, vertical: true)
      }
      Text(state.message).font(.callout).vmSupportingText()
      if state == .noMatches {
        Button("Clear Search", action: clearSearch).vmGlassControl()
      } else {
        HStack(spacing: 12) {
          Button("Open VM…", systemImage: "folder") {
            session.requestLibraryNavigation(.open)
          }
          .vmGlassControl().disabled(!session.canRequestLibraryNavigation)
          if state == .unavailable {
            Button("Reload Library", systemImage: "arrow.clockwise", action: library.reload)
              .vmGlassControl().disabled(session.trashOperationInProgress)
          }
        }
      }
    }
  }

  @ViewBuilder private func group(_ guest: GuestOS, title: String) -> some View {
    let entries = library.matching(guest)
    if !entries.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
        ForEach(entries) { entry in
          row(entry)
        }
      }
    }
  }

  private func row(_ entry: VMLibraryEntry) -> some View {
    let status = status(entry)
    let path = entry.configurationURL.deletingLastPathComponent().path
    return VMContentCard {
      HStack(alignment: .top, spacing: 16) {
        Image(systemName: "desktopcomputer").font(.title2).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          Text(entry.name).font(.headline).lineLimit(2).help(entry.name)
          Label(status.title, systemImage: status.symbol).font(.caption.weight(.medium))
          if let guidance = status.guidance {
            Text(guidance).font(.caption).vmSupportingText()
              .fixedSize(horizontal: false, vertical: true)
          }
          DisclosureGroup("Location") {
            Text(path)
              .vmSupportingText().fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled).help(path).accessibilityLabel("Location: \(path)")
          }.font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .trailing, spacing: 8) {
          Button("Open") { session.openSavedVM(entry) }
            .vmGlassControl().disabled(session.isBusy)
            .accessibilityLabel("Open \(entry.name)")
            .help("Select this VM without starting it")
          Menu("Actions") { entryActions(entry) }
            .menuStyle(.button).vmGlassControl().fixedSize()
            .accessibilityLabel("Actions for \(entry.name)")
        }
      }
    }
    .contextMenu { entryActions(entry) }
    .accessibilityAction(named: "Open VM") {
      if !session.isBusy { session.openSavedVM(entry) }
    }
    .accessibilityAction(named: "Review VM") {
      if session.canOpenSavedVMReview(entry) { session.openSavedVMReview(entry) }
    }
    .accessibilityAction(named: "Hardware settings") {
      if !session.isBusy { session.openSavedVM(entry, settings: true) }
    }
    .accessibilityAction(named: "Networking settings, experimental") {
      if session.canOpenSavedNetworkSettings(entry) { session.openSavedNetworkSettings(entry) }
    }
    .accessibilityAction(named: "Remove from library") {
      if !session.trashOperationInProgress { library.forget(entry) }
    }
    .accessibilityAction(named: "Move to Trash… · Experimental") {
      if session.canMoveSavedVMToTrash(entry) { session.moveSavedVMToTrash(entry) }
    }
  }

  @ViewBuilder private func entryActions(_ entry: VMLibraryEntry) -> some View {
    Button("Open") { session.openSavedVM(entry) }.disabled(session.isBusy)
    Button("Review VM…") { session.openSavedVMReview(entry) }
      .disabled(!session.canOpenSavedVMReview(entry))
    Button("Hardware Settings…") { session.openSavedVM(entry, settings: true) }
      .disabled(session.isBusy)
    Button("Networking Settings… · Experimental") { session.openSavedNetworkSettings(entry) }
      .disabled(!session.canOpenSavedNetworkSettings(entry))
    Divider()
    Button("Remove from Library") { library.forget(entry) }
      .disabled(session.trashOperationInProgress)
      .help("Remove this entry from the library and keep all VM files")
    Button("Move to Trash… · Experimental") { session.moveSavedVMToTrash(entry) }
      .disabled(!session.canMoveSavedVMToTrash(entry))
      .help("Review and confirm before moving this VM to Trash")
  }

  private func clearSearch() {
    library.query = ""
    searchFocused = true
  }

  private func status(_ entry: VMLibraryEntry) -> VMLibraryPresentation.RowStatus {
    VMLibraryPresentation.rowStatus(
      entryURL: entry.configurationURL, entryID: entry.vmID,
      selectedURL: session.selectedConfigurationURL, selectedID: session.configuration?.id,
      state: session.state, isActive: session.isActive, isBusy: session.isBusy,
      needsRecovery: session.needsOwnershipRecovery)
  }
}
