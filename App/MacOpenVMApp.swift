import AppKit
// SPDX-License-Identifier: Apache-2.0
import AppleVz
import BackendAPI
import Foundation
import Qemu
import SwiftUI
import UniformTypeIdentifiers
import VMCore
import VMStorage
import Virtualization

@main struct MacOpenVMApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var session = DesktopSession()
  @StateObject private var displayLab = RfbLabSession()
  private let qualificationRequest: RegisteredWindowsAppQualificationRequest?
  private let libraryNetworkQualification: LibraryNetworkAppQualificationRequest?
  private let generatedRfbQualification: GeneratedRfbAppQualificationRequest?
  private let invalidDisplayEvaluationRequest: Bool

  init() {
    do {
      let request = try WindowsDisplayEvaluationRequest.parse(
        arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
      invalidDisplayEvaluationRequest = false
      if let request {
        _session = StateObject(
          wrappedValue: DesktopSession(
            library: VMLibrary(preferences: LibraryNetworkQualificationPreferences()),
            displayEvaluation: request.display, nativeDisplayEvaluation: request.native,
            acceleratedDisplayEvaluation: request.accelerated,
            evaluationConfigurationURL: request.configurationURL,
            gpuRefreshEvaluation: request.refreshRate,
            producerCaptureEvaluation: request.producerCapture))
      }
    } catch { invalidDisplayEvaluationRequest = true }
    qualificationRequest = try? RegisteredWindowsAppQualificationRequest.parse(
      arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
    libraryNetworkQualification = try? LibraryNetworkAppQualificationRequest.parse(
      arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
    generatedRfbQualification = try? GeneratedRfbAppQualificationRequest.parse(
      arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
    if libraryNetworkQualification != nil || generatedRfbQualification != nil {
      _session = StateObject(
        wrappedValue: DesktopSession(
          library: VMLibrary(preferences: LibraryNetworkQualificationPreferences())))
    }
    if qualificationRequest != nil || libraryNetworkQualification != nil
      || generatedRfbQualification != nil
    {
      // Only the explicitly gated private qualification mode suppresses the
      // app's intentional activation; ordinary application behavior is intact.
      NSApplication.shared.setActivationPolicy(.accessory)
    }
  }
  var body: some Scene {
    Window("macOpenVM", id: "main") {
      Group {
        if invalidDisplayEvaluationRequest {
          Text(
            "The private Windows display experiment could not be validated. Reopen macOpenVM normally or use the reviewed evaluation launcher."
          )
          .padding()
        } else if let request = generatedRfbQualification {
          GeneratedRfbQualificationView(
            request: request,
            canQuit: {
              !session.isBusy && !session.isActive && !session.creating && !session.showingLibrary
                && session.configuration == nil && !displayLab.selected
            })
        } else if displayLab.selected {
          RfbLabDesktopView(session: displayLab)
        } else {
          DesktopView(session: session)
        }
      }
      .frame(minWidth: 640, minHeight: 420)
      .onAppear {
        delegate.session = session
        delegate.displayLab = displayLab
        if let request = qualificationRequest, delegate.qualificationDriver == nil {
          let driver = RegisteredWindowsAppQualification(request: request, session: session)
          delegate.qualificationDriver = driver
          Task { await driver.run() }
        }
        if let request = libraryNetworkQualification, delegate.libraryNetworkDriver == nil {
          let driver = LibraryNetworkAppQualification(request: request, session: session)
          delegate.libraryNetworkDriver = driver
          Task { await driver.run() }
        }
      }
    }
    .defaultSize(width: 900, height: 640)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {
        if generatedRfbQualification == nil {
          if displayLab.selected {
            Button("Reconnect Display") { Task { await displayLab.connectDisplay() } }
              .keyboardShortcut("r", modifiers: [.command, .shift])
          } else {
            Button("New Windows VM… · Experimental") {
              session.requestLibraryNavigation(.newWindows)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!session.canRequestLibraryNavigation)
            Button("New Linux VM…") { session.requestLibraryNavigation(.newLinux) }
              .keyboardShortcut("n").disabled(!session.canRequestLibraryNavigation)
            Button("Open VM…") { session.requestLibraryNavigation(.open) }.keyboardShortcut("o")
              .disabled(!session.canRequestLibraryNavigation)
          }
        }
      }
      CommandGroup(after: .importExport) {
        if generatedRfbQualification == nil, !displayLab.selected {
          Button("Export Support Report… · Experimental", action: session.exportSupportReport)
            .disabled(!session.canExportSupportReport)
            .help("Save a local report of host capabilities and structural VM status.")
        }
      }
      CommandMenu("Machine") {
        if generatedRfbQualification == nil {
          if displayLab.selected {
            Button("Pause") { displayLab.control(.pause) }
              .disabled(!displayLab.canControlRuntime || displayLab.state != 2)
            Button("Resume") { displayLab.control(.resume) }
              .disabled(!displayLab.canControlRuntime || displayLab.state != 4)
            Button("Force Stop…", action: displayLab.confirmForceStop)
              .disabled(!displayLab.canControlRuntime || displayLab.state == 0)
          } else {
            Button("Hardware Settings…", action: session.showHardwareSettings)
              .disabled(
                session.configuration == nil || session.isBusy || session.showingLibrary
                  || session.creating)
            Button("Disk Capacity… · Experimental", action: session.showDiskCapacitySettings)
              .disabled(!session.canEditDiskCapacity)
            Button("Start VM", action: session.start)
              .disabled(!session.canRequestStart)
            Button("Networking Settings… · Experimental", action: session.showNetworkSettings)
              .disabled(!session.canEditNetworkSettings)
              .help("Change networking for a stopped VM. Changes apply on its next start.")
            Button("Graphics Settings… · Experimental", action: session.showGraphicsSettings)
              .disabled(!session.canEditGraphicsSettings)
            Button("Copy VM… · Experimental", action: session.chooseCopyVM)
              .disabled(!session.canCopySelected)
              .help("Copy a stopped native Linux VM to a new folder on the same volume.")
            Divider()
            Button("Pause") { session.perform(.pause) }.disabled(session.state != .running)
            Button("Resume") { session.perform(.resume) }.disabled(session.state != .paused)
            Button("Shut Down") { session.perform(.stop) }.disabled(session.state != .running)
            Button("Force Stop…") { session.confirmForceStop() }
              .disabled(
                !session.isActive
                  || VMStateMachine.destination(from: session.state, operation: .forceStop) == nil)
            Divider()
            Button("Review VM…", action: session.showVMReview)
              .disabled(!session.canReviewSelectedVM)
            Divider()
            Button("Attach Installation Image…", action: session.chooseInstallationMedia)
              .disabled(session.configuration == nil || session.isBusy || session.showingLibrary)
            Button("Detach Installation Image") { session.changeInstallationMedia(nil) }
              .disabled(
                session.configuration?.installationMedia == nil || session.isBusy
                  || session.showingLibrary)
            Divider()
            Button(
              session.usesWindowsDriverDisc
                ? "Attach Windows Driver Disc · Experimental" : "Attach Tools Image…",
              action: session.chooseSupportMedia
            )
            .disabled(session.configuration == nil || session.isBusy || session.showingLibrary)
            Button(
              session.usesWindowsDriverDisc ? "Detach Windows Driver Disc" : "Detach Tools Image"
            ) {
              session.changeSupportMedia(nil)
            }
            .disabled(
              session.configuration?.supportMedia == nil || session.isBusy || session.showingLibrary
            )
          }
        }
      }
      if generatedRfbQualification == nil {
        if let display = session.windowsDisplay, !displayLab.selected {
          WindowsGuestCommands(display: display, session: session)
        } else {
          CommandGroup(after: .toolbar) {
            if displayLab.selected {
              Button("Reconnect Display") { Task { await displayLab.connectDisplay() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            } else {
              Button("Show VM Library", action: session.showLibrary)
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!session.canShowLibrary)
            }
          }
          CommandMenu("Input") {
            if displayLab.selected {
              if let error = displayLab.inputBacklogError { Text(error) }
              Button(
                displayLab.humanInput ? "Release Input" : "Release Test Input",
                action: displayLab.releaseInput
              )
              .keyboardShortcut(.escape, modifiers: [.control, .option])
              Button(
                displayLab.humanInput ? "Capture Input" : "Capture Test Input",
                action: displayLab.captureInput
              )
              .disabled(!displayLab.canCaptureInput)
              Toggle("Use Guest Cursor", isOn: $displayLab.useGuestCursor)
                .disabled(!displayLab.canChooseGuestCursor)
            } else {
              Button("Release Input", action: session.releaseInput)
                .keyboardShortcut(.escape, modifiers: [.control, .option])
              Button("Capture Input", action: session.captureInput)
                .disabled(!session.isActive)
            }
          }
        }
      }
    }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  var qualificationDriver: RegisteredWindowsAppQualification?
  var libraryNetworkDriver: LibraryNetworkAppQualification?
  weak var session: DesktopSession?
  weak var displayLab: RfbLabSession?
  private var closingDisplay = false
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    session?.releaseInput()
    displayLab?.releaseInput()
    GuestHostPointerCapture.shared.retryPendingRestoration()
    if GuestHostPointerCapture.shared.restorationPending {
      let alert = NSAlert()
      alert.messageText = "The Mac pointer has not been released yet."
      alert.informativeText =
        "macOpenVM is keeping the failed restoration available for retry. Choose Input → Release Input, then try quitting again."
      alert.addButton(withTitle: "Keep Running")
      alert.runModal()
      return .terminateCancel
    }
    if let displayLab, displayLab.selected {
      if !closingDisplay {
        closingDisplay = true
        Task { @MainActor in
          await displayLab.disconnectDisplay()
          sender.reply(toApplicationShouldTerminate: true)
        }
      }
      return .terminateLater
    }
    session?.prepareReadOnlyReviewForTermination()
    guard session?.isBusy == true else { return .terminateNow }
    let alert = NSAlert()
    if session?.needsOwnershipRecovery == true {
      alert.messageText = "Keep macOpenVM open while this VM needs recovery review."
      alert.informativeText =
        "The VM files are being preserved after an operation could not be confirmed. Inspect the VM without changing its files."
    } else if session?.isActive == true {
      alert.messageText = "Shut down the guest before quitting macOpenVM."
      alert.informativeText =
        "The VM still owns its disk. Use Machine → Shut Down, or explicitly confirm Force Stop."
    } else {
      alert.messageText = "Wait for the VM operation to finish before quitting macOpenVM."
      alert.informativeText =
        "Creation, validation and runtime history preserve the VM files while they finish."
    }
    alert.addButton(withTitle: "Keep Running")
    alert.runModal()
    return .terminateCancel
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationWillTerminate(_ notification: Notification) { session?.leavingFullscreen() }
}

protocol DesktopVMTrashTicket: Sendable {
  var vmID: UUID { get }
  var name: String { get }
  func cancel() async
  func commit() async throws -> VMTrashResult
}

extension VMTrashTicket: DesktopVMTrashTicket {}

@MainActor protocol DesktopVMTrashService {
  func prepare(entry: VMLibraryEntry) async throws -> any DesktopVMTrashTicket
}

@MainActor private struct NativeDesktopVMTrashService: DesktopVMTrashService {
  func prepare(entry: VMLibraryEntry) async throws -> any DesktopVMTrashTicket {
    let configuration = try await VMLibrarySelection.read(
      at: entry.configurationURL, expectedID: entry.vmID)
    return try await VMTrash().prepare(
      in: entry.configurationURL.deletingLastPathComponent(), expected: configuration)
  }
}

struct DesktopVMTrashConfirmation: Equatable {
  let vmID: UUID
  let name: String
  let directory: URL
}

@MainActor protocol DesktopVMTrashConfirming {
  func canPresent(on owner: NSWindow?, libraryPresented: Bool) -> Bool
  func confirm(_ request: DesktopVMTrashConfirmation, on owner: NSWindow?) async -> Bool
}

@MainActor private struct NativeDesktopVMTrashConfirmation: DesktopVMTrashConfirming {
  func canPresent(on owner: NSWindow?, libraryPresented: Bool) -> Bool {
    guard let owner else { return false }
    if libraryPresented {
      return owner.attachedSheet?.identifier == DesktopSession.librarySheetIdentifier
    }
    return owner.attachedSheet == nil
  }

  func confirm(_ request: DesktopVMTrashConfirmation, on owner: NSWindow?) async -> Bool {
    guard let owner, owner.attachedSheet == nil else { return false }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Move \(request.name) to Trash?"
    alert.informativeText =
      "The entire VM folder will move to Trash, including its disks, snapshots, platform identity and TPM state:\n\n\(request.directory.path)\n\nYou can recover it from Trash until Trash is emptied. Installation images and other files outside this folder stay in place."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Move to Trash")
    return await withCheckedContinuation { continuation in
      alert.beginSheetModal(for: owner) { response in
        continuation.resume(returning: response == .alertSecondButtonReturn)
      }
    }
  }
}

@MainActor protocol LibraryNetworkPresentation {
  func canSelect(on owner: NSWindow?) -> Bool
  func isDetached(on owner: NSWindow?) -> Bool
}

@MainActor struct NativeLibraryNetworkPresentation: LibraryNetworkPresentation {
  func canSelect(on owner: NSWindow?) -> Bool {
    owner?.attachedSheet == nil
      || owner?.attachedSheet?.identifier == DesktopSession.librarySheetIdentifier
  }
  func isDetached(on owner: NSWindow?) -> Bool { owner?.attachedSheet == nil }
}

@MainActor final class DesktopSession: ObservableObject {
  private enum LibraryDestination { case open, hardware, network, review }
  private final class LibraryReviewSelection {
    let entry: VMLibraryEntry
    let previous: VMLibraryPickerContext
    let generation: UUID
    weak var owner: NSWindow?
    init(entry: VMLibraryEntry, previous: VMLibraryPickerContext, generation: UUID, owner: NSWindow)
    {
      self.entry = entry
      self.previous = previous
      self.generation = generation
      self.owner = owner
    }
  }
  private final class LibraryNetworkSelection {
    let entry: VMLibraryEntry
    weak var owner: NSWindow?
    let ownerIdentity: ObjectIdentifier?
    init(entry: VMLibraryEntry, owner: NSWindow?) {
      self.entry = entry
      self.owner = owner
      ownerIdentity = owner.map(ObjectIdentifier.init)
    }
  }
  static let librarySheetIdentifier = NSUserInterfaceItemIdentifier("macOpenVM.vmLibrary")
  @Published var configuration: VMConfiguration? {
    didSet {
      if configuration != oldValue {
        selectionGeneration = UUID()
        creationGeneration = UUID()
        diskCapacityNotice = nil
        openHistoryAdvice = nil
        invalidateVMReview()
        if configuration?.id != oldValue?.id { clearGraphicsPreferenceSelection() }
        windowsWorker = nil
        windowsLaunchReady = false
        windowsLaunchReadiness = .notChecked
        windowsReadinessGeneration = nil
      }
    }
  }
  private var selectionGeneration = UUID()
  @Published private var openHistoryAdvice: VMOpenHistoryAdvice?
  @Published var backend: AppleVirtualMachine?
  @Published var state = VMState.stopped {
    didSet {
      if state != oldValue && ![VMState.stopped, .failed, .running, .paused].contains(state) {
        invalidateVMReview()
      }
      refreshFullscreenPresentation()
    }
  }
  private var errorGeneration = UUID()
  @Published var errorMessage: String? {
    didSet {
      errorGeneration = UUID()
      if errorMessage == nil { stoppedSettingsWarningAwaitingDetachment = false }
    }
  }
  @Published private var stoppedSettingsWarningAwaitingDetachment = false
  @Published var inputCaptured = true
  @Published var appliedPixels: PixelSize?
  @Published private(set) var fullscreen = false
  private var preparationGeneration = UUID()
  @Published var preparing = false {
    didSet {
      preparationGeneration = UUID()
      if preparing && reviewingVM { invalidateVMReview() }
    }
  }
  @Published var reviewingVM = false
  @Published private var vmReviewSheetAttached = false
  let vmReview: VMReviewController
  private var vmReviewGeneration = UUID()
  private var pendingLibraryReview: LibraryReviewSelection?
  @Published var editingHardware = false
  @Published var hardwareConfiguration: VMConfiguration?
  @Published var hardwareError: String?
  private var hardwareAdmission: DesktopStoppedSettingsAdmission?
  private var stoppedSettingsOperation: UUID?
  private let hardwareSettings: any DesktopHardwareSettingsUpdating
  @Published var editingDiskCapacity = false {
    didSet { if editingDiskCapacity != oldValue { diskCapacityGeneration = UUID() } }
  }
  private var diskCapacityGeneration = UUID()
  var diskCapacityDraftNonce: UUID { diskCapacityGeneration }
  @Published private(set) var showingDiskMetadataUpgrade = false
  @Published private var diskMetadataChecked:
    (inspection: DiskGrowthIdentityUpgradeInspection, draft: UUID, check: UUID, errors: UUID)?
  @Published private(set) var diskMetadataAcknowledged = false
  @Published private(set) var diskMetadataCheckGeneration = UUID()
  @Published private var diskMetadataResultMessage: (message: String, draft: UUID, errors: UUID)?
  private var diskMetadataRequest: DesktopDiskMetadataUpgradeRequest?
  private var diskMetadataOperation: UUID?
  private let diskMetadataUpgrade: any DesktopDiskMetadataUpgrading
  private weak var diskCapacitySheetWindow: NSWindow?
  private var diskCapacityModalGeneration = UUID()
  static let diskCapacitySheetIdentifier = NSUserInterfaceItemIdentifier("macOpenVM.diskCapacity")
  var diskMetadataDraftNonce: UUID? { diskMetadataRequest?.id }
  @Published private(set) var diskCapacityConfiguration: VMConfiguration?
  @Published private(set) var diskCapacityError: String?
  @Published private(set) var diskCapacityNotice: String?
  private var diskCapacityContext: VMLibraryPickerContext?
  private weak var diskCapacityOwner: NSWindow?
  private var diskCapacitySelectionGeneration: UUID?
  private let diskGrowth: any DesktopDiskGrowing
  private let selectionInspector: any DesktopVMSelectionInspecting
  @Published var editingNetwork = false
  @Published var editingGraphics = false
  @Published private(set) var graphicsError: String?
  @Published private(set) var graphicsPreferencesWarning: String?
  private var graphicsEditingContext: VMLibraryPickerContext?
  @Published private var graphicsPreferenceSnapshot: WindowsGraphicsPreferenceSnapshot?
  @Published var networkConfiguration: VMConfiguration?
  @Published var networkError: String?
  @Published private(set) var networkSharedPermission: SharedNetworkConfigurationPermission?
  @Published var creating = false {
    didSet { if creating != oldValue { creationGeneration = UUID() } }
  }
  private var creationGeneration = UUID()
  var creationDraftNonce: UUID { creationGeneration }
  private var creationAdmission: DesktopCreationAdmission?
  private let vmCreation: any DesktopVMCreating
  private let windowsCreationPreparation: any DesktopWindowsCreationPreparing
  private let creationLocationPresentation: any DesktopCreationLocationPresenting
  private var selectionPanelAttempt: UUID?
  @Published private(set) var windowsCreationResources: ReviewedQemuCreationResources? {
    didSet { if windowsCreationResources != oldValue { creationGeneration = UUID() } }
  }
  @Published private(set) var windowsDisplay: RfbLabSession?
  @Published private(set) var windowsLaunchReady = false
  @Published private(set) var windowsLaunchReadiness = WindowsLaunchReadiness.notChecked
  private var windowsReadinessGeneration: UUID?
  private var windowsReadinessRetryAdmissionClaimed = false
  private let windowsReadinessInspection: any DesktopWindowsReadinessInspecting
  @Published var showingLibrary = false
  @Published private var librarySheetReady = false
  private var windowObservation: DesktopWindowObservation?
  @Published private var pendingLibrarySelection: (VMLibraryEntry, LibraryDestination)?
  @Published private var pendingLibraryNavigation: VMLibraryNavigation?
  private weak var libraryNavigationOwner: NSWindow?
  private var libraryNavigationOwnerIdentity: ObjectIdentifier?
  private weak var librarySelectionOwner: NSWindow?
  private var librarySelectionOwnerIdentity: ObjectIdentifier?
  @Published private(set) var trashOperationInProgress = false
  @Published private(set) var trashRecoveryURL: URL?
  private var pendingLibraryTrash: ((any DesktopVMTrashTicket), VMLibraryEntry)?
  private weak var trashOwner: NSWindow?
  private var trashOwnerIdentity: ObjectIdentifier?
  private let trashService: any DesktopVMTrashService
  private let trashConfirmation: any DesktopVMTrashConfirming
  private let libraryNetworkPresentation: any LibraryNetworkPresentation
  let library: VMLibrary
  private let graphicsPreferences: WindowsGraphicsPreferenceStore
  private let evaluationDisplay: ReviewedQemu2DDisplay?
  private let nativeDisplayEvaluation: Bool
  private let evaluationAccelerated: Bool
  private let evaluationRefreshRate: ReviewedQemuAcceleratedDisplay.RefreshRate
  private let evaluationProducerCapture: CaptureCapability?
  private struct GraphicsSelection {
    let configurationURL: URL
    let vmID: UUID
    let settings: WindowsGraphicsSettings
  }
  @Published private var graphicsSelection: GraphicsSelection?
  private var currentGraphicsSelection: GraphicsSelection? {
    guard let selection = graphicsSelection,
      selection.configurationURL == selectedConfigurationURL, selection.vmID == configuration?.id
    else { return nil }
    return selection
  }
  var windowsGraphicsSettings: WindowsGraphicsSettings {
    currentGraphicsSelection?.settings ?? WindowsGraphicsSettings()
  }
  private var hasPrivateDisplayEvaluation: Bool {
    evaluationDisplay != nil || nativeDisplayEvaluation || evaluationAccelerated
  }
  private var displayEvaluation: ReviewedQemu2DDisplay? {
    evaluationDisplay
  }
  private var acceleratedDisplayEvaluation: Bool {
    hasPrivateDisplayEvaluation
      ? evaluationAccelerated : windowsGraphicsSettings.mode == .accelerated
  }
  private var gpuRefreshEvaluation: ReviewedQemuAcceleratedDisplay.RefreshRate {
    hasPrivateDisplayEvaluation
      ? evaluationRefreshRate : windowsGraphicsSettings.refreshRate.reviewed
  }
  private var evaluationConfigurationURL: URL?
  init(
    library: VMLibrary = VMLibrary(),
    graphicsPreferences: WindowsGraphicsPreferenceStore = WindowsGraphicsPreferenceStore(),
    trashService: any DesktopVMTrashService = NativeDesktopVMTrashService(),
    trashConfirmation: any DesktopVMTrashConfirming = NativeDesktopVMTrashConfirmation(),
    libraryNetworkPresentation: any LibraryNetworkPresentation = NativeLibraryNetworkPresentation(),
    diskGrowth: any DesktopDiskGrowing = NativeDesktopDiskGrowth(),
    diskMetadataUpgrade: any DesktopDiskMetadataUpgrading = NativeDesktopDiskMetadataUpgrade(),
    hardwareSettings: any DesktopHardwareSettingsUpdating = NativeDesktopHardwareSettings(),
    networkSettings: any DesktopNetworkSettingsUpdating = NativeDesktopNetworkSettings(),
    sharedNetworkPreparation: any DesktopSharedNetworkPreparing =
      NativeDesktopSharedNetworkPreparation(),
    mediaSettings: any DesktopMediaSettingsUpdating = NativeDesktopMediaSettings(),
    driverDiscPreparation: any DesktopWindowsDriverDiscPreparing =
      NativeDesktopWindowsDriverDiscPreparation(),
    vmCreation: any DesktopVMCreating = NativeDesktopVMCreation(),
    windowsCreationPreparation: any DesktopWindowsCreationPreparing =
      NativeDesktopWindowsCreationPreparation(),
    creationLocationPresentation: any DesktopCreationLocationPresenting =
      NativeDesktopCreationLocationPresentation(),
    windowsReadinessInspection: any DesktopWindowsReadinessInspecting =
      NativeDesktopWindowsReadinessInspection(),
    vmCopy: any DesktopVMCopying = NativeDesktopVMCopy(),
    copyPresentation: any DesktopVMCopyPresenting = NativeDesktopVMCopyPresentation(),
    supportReportExport: any DesktopSupportReportExporting = NativeDesktopSupportReportExport(),
    selectionInspector: any DesktopVMSelectionInspecting = NativeDesktopVMSelectionInspector(),
    reviewInspector: any VMReviewInspecting = NativeVMReviewInspector(),
    displayEvaluation: ReviewedQemu2DDisplay? = nil, nativeDisplayEvaluation: Bool = false,
    acceleratedDisplayEvaluation: Bool = false, evaluationConfigurationURL: URL? = nil,
    gpuRefreshEvaluation: ReviewedQemuAcceleratedDisplay.RefreshRate = .hz60,
    producerCaptureEvaluation: CaptureCapability? = nil
  ) {
    self.library = library
    self.graphicsPreferences = graphicsPreferences
    self.trashService = trashService
    self.trashConfirmation = trashConfirmation
    self.libraryNetworkPresentation = libraryNetworkPresentation
    self.diskGrowth = diskGrowth
    self.diskMetadataUpgrade = diskMetadataUpgrade
    self.hardwareSettings = hardwareSettings
    self.networkSettings = networkSettings
    self.sharedNetworkPreparation = sharedNetworkPreparation
    self.mediaSettings = mediaSettings
    self.driverDiscPreparation = driverDiscPreparation
    self.vmCreation = vmCreation
    self.windowsCreationPreparation = windowsCreationPreparation
    self.creationLocationPresentation = creationLocationPresentation
    self.windowsReadinessInspection = windowsReadinessInspection
    self.vmCopy = vmCopy
    self.copyPresentation = copyPresentation
    self.supportReportExport = supportReportExport
    self.selectionInspector = selectionInspector
    vmReview = VMReviewController(inspector: reviewInspector)
    self.evaluationDisplay = displayEvaluation
    self.nativeDisplayEvaluation = nativeDisplayEvaluation
    self.evaluationAccelerated = acceleratedDisplayEvaluation
    self.evaluationRefreshRate = gpuRefreshEvaluation
    self.evaluationProducerCapture = producerCaptureEvaluation
    self.evaluationConfigurationURL = evaluationConfigurationURL
  }
  weak var window: NSWindow? {
    didSet {
      if window !== oldValue {
        selectionGeneration = UUID()
        creationGeneration = UUID()
        invalidateVMReview()
      }
      installLegacyWindowCloseGuard()
      windowObservation = window.map { owner in
        DesktopWindowObservation(owner: owner) { [weak self, weak owner] change in
          guard let self, let owner, self.window === owner else { return }
          switch change {
          case .sheet:
            if self.showingDiskMetadataUpgrade { self.diskCapacityModalGeneration = UUID() }
            self.librarySheetReady =
              owner.attachedSheet?.identifier == Self.librarySheetIdentifier
            self.vmReviewSheetAttached =
              owner.attachedSheet?.identifier == Self.vmReviewSheetIdentifier
            self.refreshStoppedSettingsWarningGate()
          case .screen:
            self.objectWillChange.send()
          }
        }
      }
      librarySheetReady = window?.attachedSheet?.identifier == Self.librarySheetIdentifier
      vmReviewSheetAttached = window?.attachedSheet?.identifier == Self.vmReviewSheetIdentifier
      refreshStoppedSettingsWarningGate()
      guard window != nil, let url = evaluationConfigurationURL else { return }
      evaluationConfigurationURL = nil
      Task { @MainActor [weak self] in
        await Task.yield()
        // Opening follows normal inspection/admission and never starts a VM.
        self?.selectVM(at: url)
      }
    }
  }
  private weak var guestView: VZVirtualMachineView?
  private var legacyWindowCloseGuard: OwningWindowCloseDelegate?
  private var showingCloseNotice = false
  private var directory: URL? {
    didSet {
      if directory != oldValue {
        selectionGeneration = UUID()
        creationGeneration = UUID()
        openHistoryAdvice = nil
        invalidateVMReview()
        clearGraphicsPreferenceSelection()
        diskCapacityNotice = nil
      }
    }
  }
  private var networkDirectory: URL?
  private var networkAdmission: DesktopStoppedSettingsAdmission?
  private let networkSettings: any DesktopNetworkSettingsUpdating
  private let sharedNetworkPreparation: any DesktopSharedNetworkPreparing
  private let mediaSettings: any DesktopMediaSettingsUpdating
  private let driverDiscPreparation: any DesktopWindowsDriverDiscPreparing
  private let vmCopy: any DesktopVMCopying
  private let copyPresentation: any DesktopVMCopyPresenting
  private let supportReportExport: any DesktopSupportReportExporting
  private var supportReportExportAdmission: DesktopSupportReportExportAdmission?
  private var copyAdmission: DesktopStoppedSettingsAdmission?
  private var controller: VMController?
  private var recordedRuntime: DesktopRecordedRuntime?
  private var windowsRuntime: DesktopWindowsRuntime?
  private var windowsWorker: ReviewedBundledWindowsWorker?
  @Published private var lock: VMLock?
  private let files = VMFiles()
  private var presentation = GuestFullscreenPresentation()
  private var menuBarVisibility = GuestMenuBarVisibility()
  var isActive: Bool { backend?.isActive == true || windowsRuntime?.isActive == true }
  var needsOwnershipRecovery: Bool {
    recordedRuntime?.phase == .recoveryRequired || windowsRuntime?.phase == .recoveryRequired
  }
  var isBusy: Bool {
    isActive || windowsReadinessRetryAdmissionClaimed || diskMetadataOperation != nil
      || stoppedSettingsOperation != nil || supportReportExportAdmission != nil
      || preparing || creationAdmission != nil
      || lock != nil || recordedRuntime?.isBusy == true || windowsRuntime != nil
      || editingHardware
      || editingDiskCapacity
      || editingNetwork
      || editingGraphics
      || reviewingVM
      || pendingLibrarySelection != nil
      || pendingLibraryNavigation != nil
      || trashOperationInProgress
  }
  var selectedConfigurationURL: URL? { directory?.appendingPathComponent("configuration.json") }

  var currentOpenHistoryAdvice: VMOpenHistoryAdvice? {
    guard let advice = openHistoryAdvice, configuration == advice.configuration,
      selectedConfigurationURL == advice.configurationURL
    else { return nil }
    return advice
  }

  var hardwareOpenHistoryAdvice: VMOpenHistoryAdvice? {
    editorOpenHistoryAdvice(hardwareAdmission, configuration: hardwareConfiguration)
  }

  var networkOpenHistoryAdvice: VMOpenHistoryAdvice? {
    editorOpenHistoryAdvice(networkAdmission, configuration: networkConfiguration)
  }

  private func editorOpenHistoryAdvice(
    _ request: DesktopStoppedSettingsAdmission?, configuration: VMConfiguration?
  ) -> VMOpenHistoryAdvice? {
    guard let advice = currentOpenHistoryAdvice, let request,
      configuration == advice.configuration, stoppedSettingsAdmissionIsCurrent(request)
    else { return nil }
    return advice
  }

  func dismissOpenHistoryAdvice(_ id: UUID) {
    guard currentOpenHistoryAdvice?.id == id else { return }
    openHistoryAdvice = nil
  }
  var qualificationWindowsRuntime: DesktopWindowsRuntime? { windowsRuntime }
  var qualificationWindowsDisplay: RfbLabSession? { windowsDisplay }
  var isWaitingForWindowsShutdown: Bool {
    state == .stopping && windowsRuntime?.isActive == true
  }
  var usesWindowsDriverDisc: Bool {
    guard let configuration else { return false }
    return configuration.guest == .windows11 && configuration.backend == .qemuHVF
      && configuration.architecture == .arm64 && configuration.boot == .efi
  }

  var windowsDriverDiscGuidance: String {
    if acceleratedDisplayEvaluation {
      return
        "Open the driver disc in Windows to update an existing graphics driver installation or run the graphics checks."
    }
    if displayEvaluation != nil || nativeDisplayEvaluation {
      return "Open the driver disc in Windows to install display support."
    }
    return
      "When Windows asks for a network driver, choose Install driver and select drivers/netkvm on the driver disc."
  }
  var canStartSelected: Bool {
    guard let configuration, SavedVMStartEligibility.permits(configuration) else { return false }
    if configuration.guest == .linux && configuration.backend == .appleVz { return true }
    return configuration.guest == .windows11 && configuration.backend == .qemuHVF
      && configuration.architecture == .arm64 && configuration.boot == .efi
      && windowsLaunchReady && windowsWorker != nil
  }
  /// Starting belongs to the selected workspace, never a visible creation draft
  /// or library sheet. Saved resource eligibility remains a separate fact.
  var canRequestStart: Bool {
    canStartSelected && directory != nil && window?.contentView != nil
      && window?.attachedSheet == nil && !creating && !showingLibrary && !isBusy
      && (state == .stopped || state == .failed)
  }

  var canCopySelected: Bool {
    configuration?.guest == .linux && configuration?.backend == .appleVz && canStartSelected
      && directory != nil && state == .stopped
      && !isBusy && !showingLibrary && !creating
  }
  var canEditNetworkSettings: Bool {
    configuration != nil && directory != nil && state == .stopped
      && !isBusy && !showingLibrary && !creating
  }
  private var supportReportExportWorkflowIsAvailable: Bool {
    !editingHardware && !editingDiskCapacity && !editingNetwork && !editingGraphics
      && !reviewingVM && !showingLibrary && !creating && !trashOperationInProgress
  }

  var canExportSupportReport: Bool {
    window != nil && supportReportExportAdmission == nil && !preparing
      && supportReportExportWorkflowIsAvailable
  }

  static let vmReviewSheetIdentifier = NSUserInterfaceItemIdentifier("macOpenVM.vmReview")

  /// Read-only review can coexist with retained active/recovery runtime custody.
  /// It never uses general isBusy as proof that a selected guest is stopped.
  private var vmReviewWorkflowIsAvailable: Bool {
    !preparing && !editingHardware && !editingDiskCapacity && !editingNetwork && !editingGraphics
      && !creating && !showingLibrary && !trashOperationInProgress && pendingLibraryTrash == nil
      && pendingLibrarySelection == nil && pendingLibraryNavigation == nil
      && [VMState.stopped, .failed, .running, .paused].contains(state)
  }

  var canReviewSelectedVM: Bool {
    configuration != nil && selectedConfigurationURL != nil && window != nil
      && errorMessage == nil && !reviewingVM && vmReviewWorkflowIsAvailable
      && window?.attachedSheet == nil
  }

  private var vmReviewContextIsCurrent: Bool {
    guard reviewingVM, vmReviewWorkflowIsAvailable,
      let owner = window, let context = vmReview.context,
      context.owner == ObjectIdentifier(owner), context.generation == vmReviewGeneration,
      context.configurationURL == selectedConfigurationURL, context.configuration == configuration,
      owner.attachedSheet == nil || owner.attachedSheet?.identifier == Self.vmReviewSheetIdentifier
    else { return false }
    return true
  }

  var canRefreshVMReview: Bool {
    vmReviewContextIsCurrent && !vmReview.isLoading && errorMessage == nil
  }

  /// Preserve an operation error until the actual review sheet has detached.
  /// A programmatic false presentation binding must not clear its pending message.
  var canPresentOperationError: Bool {
    !reviewingVM && !vmReviewSheetAttached
      && window?.attachedSheet?.identifier != Self.vmReviewSheetIdentifier
      && !stoppedSettingsWarningAwaitingDetachment
  }

  func showVMReview() {
    guard canReviewSelectedVM else { return }
    releaseInput()
    // Input release can reenter through responder changes. Revalidate before presenting.
    guard canReviewSelectedVM, let owner = window, let configuration,
      let configurationURL = selectedConfigurationURL
    else { return }
    vmReviewGeneration = UUID()
    vmReview.open(
      VMReviewContext(
        configurationURL: configurationURL, configuration: configuration,
        owner: ObjectIdentifier(owner), generation: vmReviewGeneration))
    reviewingVM = true
    refreshVMReview()
  }

  func refreshVMReview() {
    guard canRefreshVMReview, let context = vmReview.context, let owner = window else { return }
    Task { @MainActor [weak self, weak owner] in
      guard let self else { return }
      await self.vmReview.refresh(context: context) { [weak self, weak owner] candidate in
        guard let self, let owner, self.window === owner else { return false }
        return self.vmReviewContextIsCurrent && self.vmReview.context == candidate
          && self.errorMessage == nil
      }
      if self.reviewingVM && self.vmReview.context == nil { self.closeVMReview() }
    }
  }

  /// Quit may discard a read-only review, including an in-flight refresh. Actual
  /// runtime/writer/editing work and pending operation errors remain untouched.
  func prepareReadOnlyReviewForTermination() {
    guard reviewingVM || vmReview.context != nil else { return }
    invalidateVMReview()
  }

  func closeVMReview() { invalidateVMReview() }
  func vmReviewDismissed() { invalidateVMReview() }

  private func invalidateVMReview() {
    vmReviewGeneration = UUID()
    reviewingVM = false
    vmReview.invalidate()
  }

  func registerVMReviewWindow(_ reviewWindow: NSWindow?) {
    reviewWindow?.identifier = Self.vmReviewSheetIdentifier
    vmReviewSheetAttached = reviewWindow != nil && window?.attachedSheet === reviewWindow
  }

  func canOpenSavedVMReview(_ entry: VMLibraryEntry) -> Bool {
    showingLibrary && librarySheetReady && !isBusy && !creating && !needsOwnershipRecovery
      && (state == .stopped || state == .failed) && library.entries.contains(entry)
      && window?.attachedSheet?.identifier == Self.librarySheetIdentifier
  }

  func openSavedVMReview(_ entry: VMLibraryEntry) {
    guard canOpenSavedVMReview(entry), let owner = window else { return }
    vmReviewGeneration = UUID()
    pendingLibraryReview = LibraryReviewSelection(
      entry: entry, previous: pickerContext(for: owner), generation: vmReviewGeneration,
      owner: owner)
    pendingLibrarySelection = (entry, .review)
    showingLibrary = false
  }

  private func libraryReviewSelectionIsCurrent(_ request: LibraryReviewSelection) -> Bool {
    guard let owner = request.owner, window === owner,
      ObjectIdentifier(owner) == request.previous.owner,
      vmReviewGeneration == request.generation, pickerContext(for: owner) == request.previous,
      owner.attachedSheet == nil, !showingLibrary, !creating,
      !isActive, !needsOwnershipRecovery, lock == nil, recordedRuntime?.isBusy != true,
      windowsRuntime == nil, !editingHardware, !editingDiskCapacity, !editingNetwork,
      !editingGraphics, !reviewingVM, !trashOperationInProgress,
      state == .stopped || state == .failed, library.entries.contains(request.entry)
    else { return false }
    return true
  }

  var canShowLibrary: Bool {
    !preparing && !editingHardware && !editingDiskCapacity && !editingNetwork && !editingGraphics
      && !reviewingVM && !creating && !trashOperationInProgress
      && pendingLibrarySelection == nil && pendingLibraryNavigation == nil
  }

  func showLibrary() {
    guard canShowLibrary else { return }
    releaseInput()
    library.reload()
    showingLibrary = true
  }

  var canRequestLibraryNavigation: Bool {
    guard let owner = window else { return false }
    let allowedSheet =
      showingLibrary
      ? librarySheetReady && owner.attachedSheet?.identifier == Self.librarySheetIdentifier
      : owner.attachedSheet == nil
    return allowedSheet && !needsOwnershipRecovery && !isBusy && !creating && !preparing
      && !editingHardware && !editingNetwork && pendingLibraryTrash == nil
  }

  /// A replacement assistant or picker must not compete with the library sheet.
  /// Keep its owning window and revalidate after SwiftUI detaches the sheet.
  func requestLibraryNavigation(_ destination: VMLibraryNavigation) {
    guard canRequestLibraryNavigation, let owner = window else { return }
    releaseInput()
    guard showingLibrary else {
      performLibraryNavigation(destination)
      return
    }
    libraryNavigationOwner = owner
    libraryNavigationOwnerIdentity = ObjectIdentifier(owner)
    pendingLibraryNavigation = destination
    showingLibrary = false
  }

  private func performLibraryNavigation(_ destination: VMLibraryNavigation) {
    switch destination {
    case .newWindows: showWindowsCreation()
    case .newLinux: showLinuxCreation()
    case .open: chooseVM()
    }
  }

  func openSavedVM(_ entry: VMLibraryEntry, settings: Bool = false) {
    guard showingLibrary, !isBusy else { return }
    pendingLibrarySelection = (entry, settings ? .hardware : .open)
    showingLibrary = false
  }

  func canOpenSavedNetworkSettings(_ entry: VMLibraryEntry) -> Bool {
    showingLibrary && !isBusy && !creating && state == .stopped
      && library.entries.contains(entry)
      && libraryNetworkPresentation.canSelect(on: window)
  }

  func openSavedNetworkSettings(_ entry: VMLibraryEntry) {
    guard canOpenSavedNetworkSettings(entry) else { return }
    librarySelectionOwner = window
    librarySelectionOwnerIdentity = window.map(ObjectIdentifier.init)
    pendingLibrarySelection = (entry, .network)
    showingLibrary = false
  }

  func registerLibraryWindow(_ libraryWindow: NSWindow?) {
    libraryWindow?.identifier = Self.librarySheetIdentifier
    librarySheetReady = libraryWindow != nil && window?.attachedSheet === libraryWindow
  }

  func libraryDismissed() {
    librarySheetReady = false
    if let destination = pendingLibraryNavigation {
      let owner = libraryNavigationOwner
      let identity = libraryNavigationOwnerIdentity
      pendingLibraryNavigation = nil
      libraryNavigationOwner = nil
      libraryNavigationOwnerIdentity = nil
      preparing = true
      Task { @MainActor [weak self, weak owner] in
        await Task.yield()
        guard let self else { return }
        self.preparing = false
        guard let owner, self.window === owner,
          ObjectIdentifier(owner) == identity, owner.attachedSheet == nil,
          !self.showingLibrary, self.canRequestLibraryNavigation
        else { return }
        self.performLibraryNavigation(destination)
      }
      return
    }
    if let (ticket, entry) = pendingLibraryTrash {
      pendingLibraryTrash = nil
      Task { @MainActor [self] in
        // Attach the native confirmation only after SwiftUI has detached its library sheet.
        await Task.yield()
        await finishMoveToTrash(ticket, entry: entry)
      }
      return
    }
    guard let (entry, destination) = pendingLibrarySelection else { return }
    pendingLibrarySelection = nil
    if destination == .review {
      let request = pendingLibraryReview
      pendingLibraryReview = nil
      guard let request, request.entry == entry else { return }
      preparing = true
      Task { @MainActor [weak self] in
        await Task.yield()
        guard let self else { return }
        let deadline = ContinuousClock.now + .seconds(1)
        while let owner = request.owner,
          owner.attachedSheet?.identifier == Self.librarySheetIdentifier,
          ContinuousClock.now < deadline
        {
          guard self.window === owner, self.vmReviewGeneration == request.generation,
            self.pickerContext(for: owner) == request.previous
          else { break }
          try? await Task.sleep(for: .milliseconds(20))
        }
        self.preparing = false
        guard !self.isBusy, self.libraryReviewSelectionIsCurrent(request) else { return }
        self.selectVM(
          at: entry.configurationURL, expectedID: entry.vmID, destination: .review,
          reviewSelection: request, activateWindow: false)
      }
    } else if destination == .network {
      let request = LibraryNetworkSelection(entry: entry, owner: librarySelectionOwner)
      guard request.ownerIdentity == librarySelectionOwnerIdentity else { return }
      preparing = true
      Task { @MainActor [self] in
        await Task.yield()
        preparing = false
        guard !showingLibrary, !isBusy, !creating, state == .stopped,
          libraryNetworkOwnerIsCurrent(request),
          libraryNetworkPresentation.isDetached(on: window), library.entries.contains(entry)
        else { return }
        selectVM(
          at: entry.configurationURL, expectedID: entry.vmID, destination: .network,
          networkSelection: request)
      }
    } else {
      selectVM(at: entry.configurationURL, expectedID: entry.vmID, destination: destination)
    }
  }

  private func libraryNetworkOwnerIsCurrent(_ request: LibraryNetworkSelection) -> Bool {
    window.map(ObjectIdentifier.init) == request.ownerIdentity && window === request.owner
  }

  func canMoveSavedVMToTrash(_ entry: VMLibraryEntry) -> Bool {
    entry.configurationURL.deletingLastPathComponent().pathExtension.lowercased() == "macopenvm"
      && showingLibrary && !isBusy && !creating && state == .stopped
      && trashConfirmation.canPresent(on: window, libraryPresented: true)
  }

  func moveSavedVMToTrash(_ entry: VMLibraryEntry) {
    guard canMoveSavedVMToTrash(entry), library.entries.contains(entry) else { return }
    releaseInput()
    trashRecoveryURL = nil
    trashOwner = window
    trashOwnerIdentity = window.map(ObjectIdentifier.init)
    trashOperationInProgress = true
    Task { @MainActor [self] in
      do {
        let ticket = try await trashService.prepare(entry: entry)
        guard ticket.vmID == entry.vmID, trashContextIsIdle, showingLibrary,
          library.entries.contains(entry), trashOwnerIsCurrent,
          trashConfirmation.canPresent(on: window, libraryPresented: true)
        else {
          await ticket.cancel()
          finishTrashOperation()
          showTrashSelectionChanged()
          return
        }
        pendingLibraryTrash = (ticket, entry)
        showingLibrary = false
      } catch {
        finishTrashOperation()
        show(error)
      }
    }
  }

  private var trashContextIsIdle: Bool {
    !isActive && !preparing && lock == nil && recordedRuntime?.isBusy != true
      && windowsRuntime == nil && !editingHardware && !editingNetwork && !reviewingVM && !creating
      && pendingLibrarySelection == nil && state == .stopped
  }

  private var trashOwnerIsCurrent: Bool {
    window.map(ObjectIdentifier.init) == trashOwnerIdentity && window === trashOwner
  }

  private func finishMoveToTrash(_ ticket: any DesktopVMTrashTicket, entry: VMLibraryEntry) async {
    guard trashOperationInProgress, trashContextIsIdle, !showingLibrary,
      trashOwnerIsCurrent, library.entries.contains(entry),
      trashConfirmation.canPresent(on: window, libraryPresented: false)
    else {
      await ticket.cancel()
      finishTrashOperation()
      showTrashSelectionChanged()
      return
    }
    let request = DesktopVMTrashConfirmation(
      vmID: ticket.vmID, name: ticket.name,
      directory: entry.configurationURL.deletingLastPathComponent())
    let approved = await trashConfirmation.confirm(request, on: window)
    guard approved else {
      await ticket.cancel()
      finishTrashOperation()
      return
    }
    guard trashContextIsIdle, !showingLibrary, trashOwnerIsCurrent,
      library.entries.contains(entry)
    else {
      await ticket.cancel()
      finishTrashOperation()
      showTrashSelectionChanged()
      return
    }
    defer { finishTrashOperation() }
    do {
      let result = try await ticket.commit()
      trashRecoveryURL = result.trashURL
      switch result.status {
      case .moved:
        library.forget(entry)
        clearTrashedSelectionIfSafe(entry)
        errorMessage =
          library.errorMessage == nil
          ? nil
          : "The VM folder moved to Trash, but its library entry could not be removed. Preserve the item in Trash and reload the library before opening it."
      case .notMoved:
        errorMessage =
          "The VM folder did not move to Trash. Its library entry was kept. Inspect the original folder and Trash before trying again."
      case .relocationUnverified:
        errorMessage =
          "The move to Trash could not be confirmed. The VM folder may have moved; its library entry was preserved. Inspect Trash and the original folder before opening or retrying."
        if let destination = result.trashURL {
          errorMessage = (errorMessage ?? "") + " Reported destination: " + destination.path
        }
      }
    } catch { show(error) }
  }

  private func clearTrashedSelectionIfSafe(_ entry: VMLibraryEntry) {
    guard configuration?.id == entry.vmID, selectedConfigurationURL == entry.configurationURL,
      trashContextIsIdle
    else { return }
    configuration = nil
    directory = nil
    backend = nil
    controller = nil
    recordedRuntime = nil
    windowsWorker = nil
    windowsLaunchReady = false
    windowsLaunchReadiness = .notChecked
    windowsReadinessGeneration = nil
    appliedPixels = nil
    networkSharedPermission = nil
  }

  private func finishTrashOperation() {
    pendingLibraryTrash = nil
    trashOwner = nil
    trashOwnerIdentity = nil
    trashOperationInProgress = false
  }

  private func showTrashSelectionChanged() {
    show(
      VMError(
        .staleOperation, "The VM window or operation changed before moving to Trash.",
        recovery: "Keep the VM files and reopen the library after the current operation finishes."))
  }

  func installLegacyWindowCloseGuard() {
    // Forward SwiftUI's delegate on all hosts. AppKit asks this delegate for
    // fullscreen visibility before applying its native transition defaults.
    guard let window else { return }
    if let guardDelegate = legacyWindowCloseGuard, window.delegate === guardDelegate { return }
    if let previous = legacyWindowCloseGuard, let previousWindow = previous.window,
      previousWindow.delegate === previous
    {
      previousWindow.delegate = previous.forwardedDelegate
    }
    let guardDelegate = OwningWindowCloseDelegate(
      window: window, session: self, forwardedDelegate: window.delegate)
    legacyWindowCloseGuard = guardDelegate
    window.delegate = guardDelegate
  }

  func keepOwningWindowOpen(_ owner: NSWindow) {
    guard owner === window, !showingCloseNotice, owner.attachedSheet == nil else { return }
    let alert = NSAlert()
    alert.messageText = "Keep the VM window open."
    if needsOwnershipRecovery {
      alert.informativeText =
        "The VM files are being preserved after an operation could not be confirmed. Keep this window open and inspect the VM without changing its files."
    } else {
      alert.informativeText =
        isActive
        ? "Shut down the guest before closing its window. Use Machine → Shut Down, or explicitly confirm Force Stop."
        : "Wait for creation, validation or runtime history to finish before closing the VM window."
    }
    alert.addButton(withTitle: "Keep Window Open")
    showingCloseNotice = true
    releaseInput()
    alert.beginSheetModal(for: owner) { [weak self] _ in self?.showingCloseNotice = false }
  }

  func restoreWindowDelegate(after guardDelegate: OwningWindowCloseDelegate) {
    guard legacyWindowCloseGuard === guardDelegate else { return }
    if let owner = guardDelegate.window, owner.delegate === guardDelegate {
      owner.delegate = guardDelegate.forwardedDelegate
    }
    legacyWindowCloseGuard = nil
  }

  var capabilitySummary: String {
    let report = HostProbe.capture()
    if report.virtualizationSupported && report.virtualizationEntitled
      && report.architecture == "arm64"
    {
      return "Native Linux virtualization is available on this Mac."
    }
    return
      "Native Linux virtualization is unavailable here. Review host support and use the signed build."
  }

  func chooseCreationLocation(
    folder: Bool, title: String? = nil, selected: @escaping @MainActor (URL) -> Void
  ) {
    guard !isBusy, !showingLibrary, !needsOwnershipRecovery,
      let owner = window, owner.attachedSheet == nil
    else { return }
    let panel = NSOpenPanel()
    panel.title =
      title ?? (folder ? "Choose a folder for the new VM" : "Choose your ARM64 Linux ISO")
    panel.canChooseFiles = !folder
    panel.canChooseDirectories = folder
    panel.canCreateDirectories = folder
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    if !folder { panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data] }
    beginSelectionPanel(panel, on: owner, selected: selected)
  }

  private func pickerContext(for owner: NSWindow) -> VMLibraryPickerContext {
    VMLibraryPickerContext(
      owner: ObjectIdentifier(owner), configurationURL: selectedConfigurationURL,
      configuration: configuration, creationGeneration: creationGeneration)
  }

  private func beginSelectionPanel(
    _ panel: NSOpenPanel, on owner: NSWindow, selected: @escaping @MainActor (URL) -> Void
  ) {
    let context = pickerContext(for: owner)
    let attempt = UUID()
    selectionPanelAttempt = attempt
    preparing = true
    panel.beginSheetModal(for: owner) { [weak self, weak owner] response in
      let result = response == .OK ? panel.url : nil
      Task { @MainActor [weak self, weak owner] in
        // The completion can run while AppKit still reports the closing panel.
        await Task.yield()
        let deadline = ContinuousClock.now + .seconds(1)
        while let owner, owner.attachedSheet === panel, ContinuousClock.now < deadline {
          guard let self, self.selectionPanelAttempt == attempt, self.window === owner else {
            break
          }
          try? await Task.sleep(for: .milliseconds(20))
        }
        guard let self, self.selectionPanelAttempt == attempt else { return }
        self.selectionPanelAttempt = nil
        self.preparing = false
        guard let owner, self.window === owner, self.pickerContext(for: owner) == context,
          owner.attachedSheet == nil, !self.isBusy, !self.needsOwnershipRecovery,
          !self.showingLibrary, !self.editingHardware, !self.editingNetwork, !self.editingGraphics
        else { return }
        if let result { selected(result) }
        if self.window === owner { owner.makeKeyAndOrderFront(nil) }
      }
    }
  }

  /// Views validate raw input locally, then bind error delivery to their captured draft.
  func reportCreationError(_ message: String, nonce: UUID) {
    guard creationDraftIsAvailable(nonce: nonce), errorMessage == nil else { return }
    show(VMError(.invalidConfiguration, message, recovery: "Review the new VM settings."))
  }

  func cancelCreation(nonce: UUID) {
    guard creationDraftIsAvailable(nonce: nonce) else { return }
    creating = false
  }

  /// Retained callbacks cannot use a replacement draft's picker context.
  func chooseCreationDraftLocation(
    folder: Bool, title: String? = nil, nonce: UUID,
    selected: @escaping @MainActor (URL) -> Void
  ) {
    guard creationDraftIsAvailable(nonce: nonce),
      let request = makeCreationAdmission(catalog: false)
    else { return }
    guard beginCreationPreparation(request) else { return }
    Task { [self] in
      defer { finishCreationPreparation(request) }
      guard creationAdmissionIsCurrent(request) else { return }
      let result = await creationLocationPresentation.select(
        folder: folder, title: title, on: request.owner)
      guard creationAdmissionContextIsCurrent(request),
        await waitForCreationSheetDetachment(request)
      else { return }
      // The selected closure belongs to the old StateObject; do not deliver it if stale.
      if let result { selected(result) }
    }
  }

  func creationDraftIsAvailable(nonce: UUID) -> Bool {
    creating && creationGeneration == nonce && creationWorkflowIsIdle && !preparing
      && creationAdmission == nil
      && window?.attachedSheet == nil && window != nil
  }

  /// Ignore only this request's preparing flag, never runtime or unrelated workflow custody.
  private var creationWorkflowIsIdle: Bool {
    stoppedSettingsRuntimeIsIdle && !showingLibrary && !editingHardware && !editingDiskCapacity
      && !editingNetwork && !editingGraphics && !reviewingVM && !trashOperationInProgress
      && pendingLibraryTrash == nil && pendingLibraryReview == nil && pendingLibrarySelection == nil
      && pendingLibraryNavigation == nil && !showingCloseNotice
      && selectionPanelAttempt == nil && copyAdmission == nil
  }

  private func makeCreationAdmission(catalog: Bool) -> DesktopCreationAdmission? {
    guard creationWorkflowIsIdle, !preparing, creationAdmission == nil, let owner = window,
      owner.attachedSheet == nil, creating != catalog
    else { return nil }
    return DesktopCreationAdmission(
      owner: owner, context: pickerContext(for: owner), selectionGeneration: selectionGeneration,
      nonce: creationGeneration, resources: windowsCreationResources, catalog: catalog,
      errorGeneration: errorGeneration)
  }

  private func beginCreationPreparation(_ request: DesktopCreationAdmission) -> Bool {
    // Claim busy custody before @Published can synchronously reenter another action.
    creationAdmission = request
    preparing = true
    request.preparationGeneration = preparationGeneration
    guard creationAdmissionIsCurrent(request) else {
      finishCreationPreparation(request)
      return false
    }
    return true
  }

  private func finishCreationPreparation(_ request: DesktopCreationAdmission) {
    guard creationAdmission === request else { return }
    creationAdmission = nil
    // A stale defer may release its own flag; it cannot clear a newer preparation.
    if preparing && preparationGeneration == request.preparationGeneration { preparing = false }
  }

  private func creationAdmissionIsCurrent(_ request: DesktopCreationAdmission) -> Bool {
    creationAdmissionContextIsCurrent(request) && request.owner?.attachedSheet == nil
  }

  private func waitForCreationSheetDetachment(_ request: DesktopCreationAdmission) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(1)
    // Only physical detachment is relaxed here; the original context remains mandatory.
    while creationAdmissionContextIsCurrent(request), request.owner?.attachedSheet != nil,
      ContinuousClock.now < deadline
    {
      try? await Task.sleep(for: .milliseconds(20))
    }
    return creationAdmissionIsCurrent(request)
  }

  private func creationAdmissionContextIsCurrent(_ request: DesktopCreationAdmission) -> Bool {
    guard preparing, creationAdmission === request,
      preparationGeneration == request.preparationGeneration,
      creationWorkflowIsIdle, creating != request.catalog,
      creationGeneration == request.nonce, windowsCreationResources == request.resources,
      selectionGeneration == request.selectionGeneration,
      let owner = request.owner, window === owner
    else { return false }
    return pickerContext(for: owner) == request.context
  }

  private func surfaceCreationFailure(_ message: String, request: DesktopCreationAdmission) {
    guard creationAdmissionIsCurrent(request), errorGeneration == request.errorGeneration,
      errorMessage == nil
    else { return }
    show(VMError(.staleOperation, message, recovery: "Preserve new VM files and inspect them."))
  }

  func chooseInstallationMedia() {
    guard !isBusy, configuration != nil, directory != nil else { return }
    chooseCreationLocation(folder: false) { [weak self] url in self?.changeInstallationMedia(url) }
  }

  func changeInstallationMedia(_ selected: URL?) {
    changeMedia(selected, support: false)
  }

  func chooseSupportMedia() {
    guard !isBusy, configuration != nil, directory != nil else { return }
    if usesWindowsDriverDisc {
      attachWindowsDriverDisc()
      return
    }
    chooseCreationLocation(folder: false, title: "Choose a tools ISO for this VM") {
      [weak self] url in
      self?.changeSupportMedia(url)
    }
  }

  func changeSupportMedia(_ selected: URL?) {
    changeMedia(selected, support: true)
  }

  private func attachWindowsDriverDisc() {
    guard !isBusy, !showingLibrary, !creating, usesWindowsDriverDisc,
      stoppedSettingsRuntimeIsIdle, let original = configuration, let directory,
      let request = stoppedSettingsAdmission()
    else { return }
    let accelerated = acceleratedDisplayEvaluation
    let displayExperiment = displayEvaluation != nil || nativeDisplayEvaluation
    preparing = true
    Task { [self] in
      defer { preparing = false }
      guard mediaAdmissionIsCurrent(request) else { return }
      do {
        let image = try await driverDiscPreparation.imageURL(
          accelerated: accelerated, displayExperiment: displayExperiment)
        // The verified catalog result belongs to the original UI request. Keep
        // preparing true and use that request through the actual Core write.
        guard mediaAdmissionIsCurrent(request) else { return }
        await updateMedia(
          image, support: true, in: directory, original: original, request: request)
      } catch {
        guard mediaAdmissionIsCurrent(request) else { return }
        surfaceStoppedSettingsError(
          "The driver disc could not be prepared. Preserve the VM and reopen it before retrying.",
          editorPresented: false)
      }
    }
  }

  private func mediaAdmissionIsCurrent(_ request: DesktopStoppedSettingsAdmission) -> Bool {
    preparing && !showingLibrary && !creating && stoppedSettingsRuntimeIsIdle
      && stoppedSettingsAdmissionIsCurrent(request)
  }

  private func changeMedia(_ selected: URL?, support: Bool) {
    guard !isBusy, !showingLibrary, !creating, stoppedSettingsRuntimeIsIdle,
      let directory, let original = configuration, let request = stoppedSettingsAdmission()
    else { return }
    preparing = true
    Task { [self] in
      defer { preparing = false }
      await updateMedia(
        selected, support: support, in: directory, original: original, request: request)
    }
  }

  private func updateMedia(
    _ selected: URL?, support: Bool, in directory: URL, original: VMConfiguration,
    request: DesktopStoppedSettingsAdmission
  ) async {
    // This executes after the queued Task enters, before the ordinary writer.
    guard mediaAdmissionIsCurrent(request) else { return }
    do {
      let replacement = try await mediaSettings.update(
        in: directory, expected: original, selected: selected, support: support)
      var expected = original
      if support {
        expected.supportMedia = selected?.path
      } else {
        expected.installationMedia = selected?.path
      }
      guard replacement == expected else {
        throw VMError(
          .storage, "The media-settings save could not be confirmed.",
          recovery: "Preserve the VM and reopen its saved configuration.")
      }
      guard mediaAdmissionIsCurrent(request) else {
        surfaceStoppedSettingsError(
          "The media settings were saved. Reopen the VM to review them.", editorPresented: false)
        invalidateStoppedSettingsSelection(ifMatching: request)
        return
      }
      configuration = replacement
      backend = nil
      controller = nil
      state = .stopped
      await refreshWindowsLaunchReadiness(for: replacement)
    } catch {
      let message =
        (error as? VMError)?.errorDescription
        ?? "The media change could not be confirmed. Preserve the VM and reopen its configuration."
      surfaceStoppedSettingsError(message, editorPresented: false)
      // A rename may have committed before a directory flush or delivery failed.
      // Never roll it back, clear an unrelated replacement, or erase a newer error.
      let current = try? ConfigurationCodec.decode(
        await files.readMetadata(at: directory.appendingPathComponent("configuration.json")))
      if current != original { invalidateStoppedSettingsSelection(ifMatching: request) }
    }
  }

  private func stoppedSettingsAdmission() -> DesktopStoppedSettingsAdmission? {
    guard let owner = window, owner.attachedSheet == nil,
      configuration != nil, selectedConfigurationURL != nil
    else { return nil }
    return DesktopStoppedSettingsAdmission(
      owner: owner, context: pickerContext(for: owner), generation: selectionGeneration)
  }

  private func stoppedSettingsAdmissionIsCurrent(_ request: DesktopStoppedSettingsAdmission) -> Bool
  {
    guard let owner = request.owner, window === owner,
      selectionGeneration == request.generation
    else { return false }
    return pickerContext(for: owner) == request.context
  }

  private var stoppedSettingsRuntimeIsIdle: Bool {
    !isActive && !needsOwnershipRecovery && lock == nil && recordedRuntime?.isBusy != true
      && windowsRuntime == nil && (state == .stopped || state == .failed)
  }

  /// Claim before @Published can synchronously reenter another save. The weak
  /// editor admission still binds the owner, selection and actual Core transaction.
  private func beginStoppedSettingsOperation() -> (id: UUID, preparation: UUID)? {
    guard stoppedSettingsOperation == nil, !preparing else { return nil }
    let operation = UUID()
    stoppedSettingsOperation = operation
    preparing = true
    return (operation, preparationGeneration)
  }

  private func stoppedSettingsOperationIsCurrent(
    _ operation: UUID, preparation: UUID
  ) -> Bool {
    stoppedSettingsOperation == operation && preparing && preparationGeneration == preparation
  }

  private func finishStoppedSettingsOperation(_ operation: UUID, preparation: UUID) {
    guard stoppedSettingsOperation == operation else { return }
    stoppedSettingsOperation = nil
    if preparing && preparationGeneration == preparation { preparing = false }
  }

  private func invalidateStoppedSettingsSelection(
    ifMatching request: DesktopStoppedSettingsAdmission
  ) {
    guard selectedConfigurationURL == request.context.configurationURL,
      configuration == request.context.configuration
    else { return }
    configuration = nil
    directory = nil
    backend = nil
    controller = nil
    appliedPixels = nil
    state = .stopped
  }

  private func refreshStoppedSettingsWarningGate() {
    guard stoppedSettingsWarningAwaitingDetachment, window?.attachedSheet == nil else { return }
    stoppedSettingsWarningAwaitingDetachment = false
  }

  private func surfaceStoppedSettingsError(_ message: String, editorPresented: Bool) {
    guard !editorPresented, errorMessage == nil else { return }
    stoppedSettingsWarningAwaitingDetachment = window?.attachedSheet != nil
    show(
      VMError(.staleOperation, message, recovery: "Preserve the VM and reopen it for inspection."))
  }

  func showHardwareSettings() {
    guard !isBusy, !showingLibrary, !creating, stoppedSettingsRuntimeIsIdle,
      let configuration, let request = stoppedSettingsAdmission()
    else { return }
    releaseInput()
    guard !isBusy, !showingLibrary, !creating, stoppedSettingsRuntimeIsIdle,
      stoppedSettingsAdmissionIsCurrent(request)
    else { return }
    hardwareAdmission = request
    hardwareConfiguration = configuration
    hardwareError = nil
    editingHardware = true
  }

  func hardwareSettingsDismissed() {
    guard !preparing else { return }
    hardwareAdmission = nil
    hardwareConfiguration = nil
    hardwareError = nil
  }

  func saveHardware(cpuCount: Int, memoryBytes: UInt64) {
    guard editingHardware, !editingNetwork, !editingDiskCapacity, !editingGraphics,
      !reviewingVM, !creating, !showingLibrary, !preparing, stoppedSettingsOperation == nil,
      stoppedSettingsRuntimeIsIdle,
      let request = hardwareAdmission, stoppedSettingsAdmissionIsCurrent(request),
      let original = hardwareConfiguration, configuration == original,
      let directory, selectedConfigurationURL == request.context.configurationURL
    else {
      hardwareError = "Cancel and reopen the stopped VM before editing its settings."
      return
    }
    guard let operation = beginStoppedSettingsOperation() else { return }
    hardwareError = nil
    Task { [self] in
      defer {
        finishStoppedSettingsOperation(operation.id, preparation: operation.preparation)
        if !editingHardware { hardwareSettingsDismissed() }
      }
      do {
        guard stoppedSettingsOperationIsCurrent(operation.id, preparation: operation.preparation),
          editingHardware, hardwareAdmission === request,
          stoppedSettingsRuntimeIsIdle, stoppedSettingsAdmissionIsCurrent(request)
        else {
          hardwareError = "Cancel and reopen the stopped VM before editing its settings."
          return
        }
        let replacement = try await hardwareSettings.update(
          in: directory, expected: original, cpuCount: cpuCount, memoryBytes: memoryBytes)
        var expected = original
        expected.cpuCount = cpuCount
        expected.memoryBytes = memoryBytes
        guard replacement == expected else {
          throw VMError(
            .storage, "The hardware-settings save could not be confirmed.",
            recovery: "Preserve the VM and reopen its saved configuration.")
        }
        guard stoppedSettingsOperationIsCurrent(operation.id, preparation: operation.preparation),
          hardwareAdmission === request, stoppedSettingsAdmissionIsCurrent(request)
        else {
          let message = "The settings were saved. Cancel and reopen the VM to review them."
          hardwareError = message
          surfaceStoppedSettingsError(message, editorPresented: editingHardware)
          invalidateStoppedSettingsSelection(ifMatching: request)
          return
        }
        configuration = replacement
        backend = nil
        controller = nil
        state = .stopped
        editingHardware = false
        await refreshWindowsLaunchReadiness(for: replacement)
      } catch {
        let message =
          (error as? VMError)?.errorDescription
          ?? "The save could not be confirmed. Preserve the VM and reopen its configuration."
        hardwareError = message
        surfaceStoppedSettingsError(message, editorPresented: editingHardware)
        let current = try? ConfigurationCodec.decode(
          await files.readMetadata(at: directory.appendingPathComponent("configuration.json")))
        if current != original { invalidateStoppedSettingsSelection(ifMatching: request) }
      }
    }
  }

  var canEditDiskCapacity: Bool {
    configuration != nil && directory != nil && state == .stopped
      && !isBusy && !needsOwnershipRecovery && !showingLibrary && !creating
  }

  var canSaveDiskCapacity: Bool {
    guard editingDiskCapacity, !showingDiskMetadataUpgrade, !preparing, !isActive,
      stoppedSettingsOperation == nil,
      !needsOwnershipRecovery,
      !editingHardware, !editingNetwork, !editingGraphics, !reviewingVM, !showingLibrary, !creating,
      lock == nil, recordedRuntime?.isBusy != true, windowsRuntime == nil,
      state == .stopped, let context = diskCapacityContext,
      let generation = diskCapacitySelectionGeneration
    else { return false }
    return diskCapacityAdmissionIsCurrent(context: context, generation: generation)
  }

  private func diskCapacityAdmissionIsCurrent(
    context: VMLibraryPickerContext, generation: UUID
  ) -> Bool {
    guard diskCapacityContext == context, diskCapacitySelectionGeneration == generation,
      selectionGeneration == generation, let owner = window, diskCapacityOwner === owner
    else { return false }
    return context == pickerContext(for: owner) && configuration == diskCapacityConfiguration
  }

  func showDiskCapacitySettings() {
    guard canEditDiskCapacity, let owner = window, owner.attachedSheet == nil,
      let configuration
    else { return }
    releaseInput()
    guard canEditDiskCapacity, window === owner, owner.attachedSheet == nil,
      self.configuration == configuration
    else { return }
    diskCapacityContext = pickerContext(for: owner)
    diskCapacityOwner = owner
    diskCapacitySelectionGeneration = selectionGeneration
    diskCapacityConfiguration = configuration
    diskCapacityError = nil
    editingDiskCapacity = true
  }

  func cancelDiskCapacitySettings(draft nonce: UUID) {
    guard nonce == diskCapacityGeneration, !preparing, !showingDiskMetadataUpgrade else { return }
    editingDiskCapacity = false
  }

  func diskCapacitySettingsDismissed() {
    guard !preparing else { return }
    clearDiskMetadataUpgrade()
    diskCapacitySheetWindow = nil
    diskCapacityConfiguration = nil
    diskCapacityContext = nil
    diskCapacityOwner = nil
    diskCapacitySelectionGeneration = nil
    diskCapacityError = nil
  }

  var diskMetadataInspection: DiskGrowthIdentityUpgradeInspection? {
    guard let checked = diskMetadataChecked, let request = diskMetadataRequest,
      checked.draft == request.id, checked.check == diskMetadataCheckGeneration,
      checked.errors == errorGeneration, diskMetadataAdmissionIsCurrent(request)
    else { return nil }
    return checked.inspection
  }

  var diskMetadataMessage: String? {
    guard let result = diskMetadataResultMessage, let request = diskMetadataRequest,
      result.draft == request.id, result.errors == errorGeneration,
      diskMetadataAdmissionIsCurrent(request)
    else { return nil }
    return result.message
  }

  func registerDiskCapacityWindow(_ sheet: NSWindow?) {
    if diskCapacitySheetWindow !== sheet { diskCapacityModalGeneration = UUID() }
    sheet?.identifier = Self.diskCapacitySheetIdentifier
    diskCapacitySheetWindow = sheet
  }

  private var diskCapacitySheetIsAllowed: Bool {
    guard let owner = window else { return false }
    return owner.attachedSheet == nil
      || (owner.attachedSheet === diskCapacitySheetWindow
        && diskCapacitySheetWindow?.identifier == Self.diskCapacitySheetIdentifier)
  }

  var canInspectDiskMetadata: Bool {
    canSaveDiskCapacity && errorMessage == nil && diskMetadataOperation == nil
      && diskCapacitySheetIsAllowed
  }

  func showDiskMetadataUpgrade(draft nonce: UUID) {
    guard nonce == diskCapacityGeneration, canInspectDiskMetadata,
      let owner = diskCapacityOwner, let context = diskCapacityContext,
      let selection = diskCapacitySelectionGeneration
    else { return }
    let request = DesktopDiskMetadataUpgradeRequest(
      owner: owner, context: context, selection: selection, draft: nonce,
      modal: diskCapacityModalGeneration)
    diskMetadataRequest = request
    showingDiskMetadataUpgrade = true
    refreshDiskMetadataUpgrade(draft: request.id)
  }

  func diskMetadataSelectionIsCurrent(draft nonce: UUID) -> Bool {
    guard let request = diskMetadataRequest, request.id == nonce else { return false }
    return diskMetadataAdmissionIsCurrent(request)
  }

  private func diskMetadataAdmissionIsCurrent(_ request: DesktopDiskMetadataUpgradeRequest) -> Bool
  {
    guard diskMetadataRequest === request, showingDiskMetadataUpgrade, editingDiskCapacity,
      request.draftGeneration == diskCapacityGeneration,
      request.modalGeneration == diskCapacityModalGeneration,
      request.selectionGeneration == selectionGeneration,
      let owner = request.owner, window === owner, diskCapacityOwner === owner,
      diskCapacitySheetIsAllowed, pickerContext(for: owner) == request.context,
      diskCapacityContext == request.context, configuration == diskCapacityConfiguration,
      stoppedSettingsRuntimeIsIdle, state == .stopped,
      !editingHardware, !editingNetwork, !editingGraphics, !reviewingVM, !showingLibrary,
      !creating, !trashOperationInProgress, pendingLibrarySelection == nil,
      pendingLibraryNavigation == nil, pendingLibraryTrash == nil
    else { return false }
    return true
  }

  var canRefreshDiskMetadataUpgrade: Bool {
    guard let request = diskMetadataRequest else { return false }
    return diskMetadataAdmissionIsCurrent(request) && !preparing
      && diskMetadataOperation == nil && errorMessage == nil
  }

  var canConfirmDiskMetadataUpgrade: Bool {
    guard canRefreshDiskMetadataUpgrade, diskMetadataAcknowledged,
      let inspection = diskMetadataInspection, inspection.status == .eligibleAtCheck,
      inspection.eligibleAtCheck, inspection.vmID == configuration?.id,
      inspection.vmID != nil, inspection.transactionID != nil
    else { return false }
    return true
  }

  func acknowledgeDiskMetadataUpgrade(_ acknowledged: Bool, draft nonce: UUID, check: UUID) {
    guard diskMetadataRequest?.id == nonce, diskMetadataCheckGeneration == check,
      canRefreshDiskMetadataUpgrade,
      diskMetadataInspection?.status == .eligibleAtCheck
    else { return }
    // Published sends before storing the new value; nested confirmation must not see the old acknowledgement.
    let admission = UUID()
    diskMetadataOperation = admission
    diskMetadataAcknowledged = acknowledged
    if diskMetadataOperation == admission { diskMetadataOperation = nil }
  }

  private func diskMetadataOperationIsCurrent(
    _ request: DesktopDiskMetadataUpgradeRequest, operation: UUID,
    preparation: UUID, errors: UUID
  ) -> Bool {
    diskMetadataOperation == operation && preparationGeneration == preparation && preparing
      && errorGeneration == errors && errorMessage == nil
      && diskMetadataAdmissionIsCurrent(request)
  }

  private func finishDiskMetadataOperation(_ operation: UUID, preparation: UUID) {
    guard diskMetadataOperation == operation else { return }
    diskMetadataOperation = nil
    if preparationGeneration == preparation { preparing = false }
    if !editingDiskCapacity && !preparing { diskCapacitySettingsDismissed() }
  }

  func refreshDiskMetadataUpgrade(draft nonce: UUID) {
    guard diskMetadataRequest?.id == nonce, canRefreshDiskMetadataUpgrade,
      let request = diskMetadataRequest, let registration = request.context.configurationURL,
      let expected = request.context.configuration
    else { return }
    let operation = UUID()
    let errors = errorGeneration
    diskMetadataOperation = operation
    diskMetadataCheckGeneration = UUID()
    preparing = true
    let preparation = preparationGeneration
    diskMetadataChecked = nil
    diskMetadataAcknowledged = false
    diskMetadataResultMessage = nil
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { finishDiskMetadataOperation(operation, preparation: preparation) }
      let accepting: @MainActor @Sendable () -> Bool = { [weak self] in
        self?.diskMetadataOperationIsCurrent(
          request, operation: operation, preparation: preparation, errors: errors) == true
      }
      guard accepting() else { return }
      do {
        let inspection = try await diskMetadataUpgrade.inspect(
          at: registration, expected: expected, accepting: accepting)
        guard accepting() else { return }
        diskMetadataChecked = (inspection, request.id, diskMetadataCheckGeneration, errors)
      } catch {
        guard accepting() else { return }
        diskMetadataResultMessage = (
          "The compatibility check could not be completed. Preserve the VM and check again.",
          request.id, errors
        )
      }
    }
  }

  func confirmDiskMetadataUpgrade(
    draft nonce: UUID, check: UUID, inspectedVMID: UUID, transactionID: UUID
  ) {
    guard diskMetadataRequest?.id == nonce, diskMetadataCheckGeneration == check,
      canConfirmDiskMetadataUpgrade,
      diskMetadataInspection?.vmID == inspectedVMID,
      diskMetadataInspection?.transactionID == transactionID,
      let request = diskMetadataRequest, let registration = request.context.configurationURL,
      let expected = request.context.configuration
    else { return }
    let operation = UUID()
    let errors = errorGeneration
    diskMetadataOperation = operation
    diskMetadataCheckGeneration = UUID()
    preparing = true
    let preparation = preparationGeneration
    diskMetadataChecked = nil
    diskMetadataAcknowledged = false
    diskMetadataResultMessage = nil
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { finishDiskMetadataOperation(operation, preparation: preparation) }
      let accepting: @MainActor @Sendable () -> Bool = { [weak self] in
        self?.diskMetadataOperationIsCurrent(
          request, operation: operation, preparation: preparation, errors: errors) == true
      }
      guard accepting() else { return }
      var confirmed = false
      do {
        let result = try await diskMetadataUpgrade.upgrade(
          at: registration, expected: expected, inspectedVMID: inspectedVMID,
          transactionID: transactionID, acknowledgement: .schema1OnlyAppsCannotOpenSchema2,
          accepting: accepting)
        confirmed =
          result.changed && result.vmID == inspectedVMID
          && result.transactionID == transactionID
      } catch {
        // Core may have archived or replaced the journal before delivery failed.
        // No rollback, deletion, automatic retry or runtime/selection reset occurs.
      }
      // Re-inspect the original location after either outcome, even if its UI was replaced.
      // This read-only follow-up grants no new authority and is never attached to stale UI.
      let inspection = try? await diskMetadataUpgrade.inspect(
        at: registration, expected: expected, accepting: { true })
      guard accepting() else { return }
      diskMetadataChecked = inspection.map { ($0, request.id, diskMetadataCheckGeneration, errors) }
      guard accepting() else { return }
      let message =
        confirmed && inspection?.status == .alreadyStable
        ? "The compatibility record was upgraded. Older versions, including App79, can no longer open this VM. The latest check is shown above."
        : "The upgrade could not be confirmed. Preserve the VM and every record. No change was undone or retried; check again if no result is shown above."
      diskMetadataResultMessage = (message, request.id, errors)
    }
  }

  func leaveDiskMetadataUpgrade(draft nonce: UUID, closeSheet: Bool) {
    guard diskMetadataRequest?.id == nonce, showingDiskMetadataUpgrade,
      diskMetadataOperation == nil, !preparing
    else { return }
    diskCapacityGeneration = UUID()
    clearDiskMetadataUpgrade()
    if closeSheet { editingDiskCapacity = false }
  }

  private func clearDiskMetadataUpgrade() {
    diskMetadataRequest = nil
    diskMetadataCheckGeneration = UUID()
    showingDiskMetadataUpgrade = false
    diskMetadataChecked = nil
    diskMetadataAcknowledged = false
    diskMetadataResultMessage = nil
  }

  func saveDiskCapacity(targetBytes: UInt64, draft nonce: UUID) {
    guard nonce == diskCapacityGeneration, !showingDiskMetadataUpgrade else { return }
    guard canSaveDiskCapacity, let original = diskCapacityConfiguration,
      let context = diskCapacityContext, let generation = diskCapacitySelectionGeneration,
      let directory
    else {
      diskCapacityError = "Cancel and reopen the stopped VM before expanding its disk."
      return
    }
    do { try DiskCapacityDraft.validate(targetBytes, largerThan: original.diskBytes) } catch {
      diskCapacityError = (error as? VMError)?.errorDescription
      return
    }
    guard let operation = beginStoppedSettingsOperation() else { return }
    diskCapacityError = nil
    Task { [self] in
      defer {
        finishStoppedSettingsOperation(operation.id, preparation: operation.preparation)
        if !editingDiskCapacity { diskCapacitySettingsDismissed() }
      }
      do {
        guard stoppedSettingsOperationIsCurrent(operation.id, preparation: operation.preparation),
          editingDiskCapacity, nonce == diskCapacityGeneration, !showingDiskMetadataUpgrade,
          diskCapacityAdmissionIsCurrent(context: context, generation: generation)
        else {
          diskCapacityError = "Cancel and reopen the stopped VM before expanding its disk."
          return
        }
        let replacement = try await diskGrowth.grow(
          in: directory, expected: original, targetBytes: targetBytes)
        var expected = original
        expected.diskBytes = targetBytes
        guard replacement == expected else {
          throw VMError(
            .storage, "The disk expansion result could not be confirmed.",
            recovery: "Preserve the VM and reopen it for inspection before retrying.")
        }
        guard stoppedSettingsOperationIsCurrent(operation.id, preparation: operation.preparation),
          diskCapacityAdmissionIsCurrent(context: context, generation: generation)
        else {
          let message =
            "The selected VM changed. Reopen it to inspect the completed disk expansion."
          diskCapacityError = message
          surfaceStoppedSettingsError(message, editorPresented: editingDiskCapacity)
          invalidateDiskCapacitySelection(ifMatching: context)
          return
        }
        configuration = replacement
        backend = nil
        controller = nil
        editingDiskCapacity = false
        diskCapacityNotice =
          "Virtual disk expanded. Expand the partition inside the guest to use the added space."
        await refreshWindowsLaunchReadiness(for: replacement)
      } catch {
        let message =
          "Disk expansion could not be confirmed. Preserve the VM and its files; cancel and reopen it for inspection before retrying."
        diskCapacityError = message
        surfaceStoppedSettingsError(message, editorPresented: editingDiskCapacity)
        // Even an unchanged registration can accompany a pending disk transaction.
        // Do not leave stale configuration startable after an uncertain result.
        invalidateDiskCapacitySelection(ifMatching: context)
      }
    }
  }

  private func invalidateDiskCapacitySelection(ifMatching context: VMLibraryPickerContext) {
    guard selectedConfigurationURL == context.configurationURL,
      configuration == context.configuration
    else { return }
    configuration = nil
    directory = nil
    backend = nil
    controller = nil
  }

  func showNetworkSettings() {
    guard canEditNetworkSettings, let configuration, let directory,
      let request = stoppedSettingsAdmission()
    else { return }
    releaseInput()
    guard canEditNetworkSettings, stoppedSettingsAdmissionIsCurrent(request) else { return }
    networkSharedPermission = nil
    if usesWindowsDriverDisc {
      preparing = true
      Task { [self] in
        guard stoppedSettingsAdmissionIsCurrent(request), stoppedSettingsRuntimeIsIdle else {
          preparing = false
          return
        }
        var permission: SharedNetworkConfigurationPermission?
        var availabilityError: String?
        do {
          permission = try await sharedNetworkPreparation.permission(for: configuration)
        } catch {
          availabilityError =
            "Shared networking is unavailable in this build. You can keep this VM disconnected."
        }
        preparing = false
        guard canEditNetworkSettings, stoppedSettingsAdmissionIsCurrent(request),
          self.configuration == configuration, self.directory == directory,
          window?.attachedSheet == nil
        else { return }
        networkAdmission = request
        networkConfiguration = configuration
        networkDirectory = directory
        networkSharedPermission = permission
        networkError = availabilityError
        editingNetwork = true
      }
      return
    }
    networkAdmission = request
    networkConfiguration = configuration
    networkDirectory = directory
    networkError = nil
    editingNetwork = true
  }

  func networkSettingsDismissed() {
    guard !preparing else { return }
    networkAdmission = nil
    networkSharedPermission = nil
    networkConfiguration = nil
    networkDirectory = nil
    networkError = nil
  }

  func saveNetwork(mode: NetworkMode) {
    guard editingNetwork, !editingHardware, !editingDiskCapacity, !editingGraphics,
      !reviewingVM, !creating, !showingLibrary, !preparing, stoppedSettingsOperation == nil,
      stoppedSettingsRuntimeIsIdle,
      state == .stopped, pendingLibrarySelection == nil,
      let request = networkAdmission, stoppedSettingsAdmissionIsCurrent(request),
      let original = networkConfiguration, configuration == original,
      let directory = networkDirectory, self.directory == directory
    else {
      networkError = "Cancel and reopen the stopped VM before editing its networking."
      return
    }
    let permission = networkSharedPermission
    releaseInput()
    guard stoppedSettingsAdmissionIsCurrent(request), stoppedSettingsRuntimeIsIdle else {
      networkError = "Cancel and reopen the stopped VM before editing its networking."
      return
    }
    guard let operation = beginStoppedSettingsOperation() else { return }
    networkError = nil
    Task { [self] in
      defer {
        finishStoppedSettingsOperation(operation.id, preparation: operation.preparation)
        if !editingNetwork { networkSettingsDismissed() }
      }
      do {
        guard stoppedSettingsOperationIsCurrent(operation.id, preparation: operation.preparation),
          editingNetwork, networkAdmission === request, state == .stopped,
          stoppedSettingsRuntimeIsIdle, stoppedSettingsAdmissionIsCurrent(request)
        else {
          networkError = "Cancel and reopen the stopped VM before editing its networking."
          return
        }
        let replacement = try await networkSettings.update(
          in: directory, expected: original, mode: mode, sharedPermission: permission)
        var expected = original
        expected.network = mode
        guard replacement == expected else {
          throw VMError(
            .storage, "The networking save could not be confirmed.",
            recovery: "Preserve the VM and reopen its saved configuration.")
        }
        guard stoppedSettingsOperationIsCurrent(operation.id, preparation: operation.preparation),
          networkAdmission === request, stoppedSettingsAdmissionIsCurrent(request)
        else {
          let message = "The settings were saved. Cancel and reopen the VM to review them."
          networkError = message
          surfaceStoppedSettingsError(message, editorPresented: editingNetwork)
          invalidateStoppedSettingsSelection(ifMatching: request)
          return
        }
        configuration = replacement
        backend = nil
        controller = nil
        appliedPixels = nil
        state = .stopped
        editingNetwork = false
        networkSharedPermission = nil
        await refreshWindowsLaunchReadiness(for: replacement)
      } catch {
        let message =
          (error as? VMError)?.errorDescription
          ?? "The save could not be confirmed. Preserve the VM and reopen its configuration."
        networkError = message
        surfaceStoppedSettingsError(message, editorPresented: editingNetwork)
        let current = try? ConfigurationCodec.decode(
          await files.readMetadata(at: directory.appendingPathComponent("configuration.json")))
        if current != original { invalidateStoppedSettingsSelection(ifMatching: request) }
      }
    }
  }

  func createVM(_ c: VMConfiguration, in destination: URL, nonce: UUID) {
    guard creationDraftIsAvailable(nonce: nonce), windowsCreationResources == nil else { return }
    guard c.guest == .linux, c.backend == .appleVz, c.architecture == .arm64, c.boot == .efi else {
      reportCreationError(
        "Choose the ARM64 Linux EFI profile and an installation image.", nonce: nonce)
      return
    }
    submitCreation(c, in: destination, resources: nil)
  }

  private func submitCreation(
    _ c: VMConfiguration, in destination: URL, resources: ReviewedQemuCreationResources?
  ) {
    guard let request = makeCreationAdmission(catalog: false), request.resources == resources else {
      return
    }
    guard beginCreationPreparation(request) else { return }
    Task { [self] in
      defer { finishCreationPreparation(request) }
      // A queued request must still own its original owner, selection and draft.
      guard creationAdmissionIsCurrent(request) else { return }
      do {
        if let resources {
          try await vmCreation.createWindows(c, at: destination, resources: resources)
        } else {
          try await vmCreation.createLinux(c, at: destination)
        }
        // Core confirmed the registration commit. Preserve and remember it even
        // when the UI request is stale; never delete or roll back the new folder.
        library.remember(c, at: destination.appendingPathComponent("configuration.json"))
        guard creationAdmissionIsCurrent(request) else { return }
        if library.errorMessage != nil {
          surfaceCreationFailure(
            "The VM was created, but its library entry could not be saved. Preserve its new folder and open it for inspection.",
            request: request)
        }
        configuration = c
        directory = destination
        restoreGraphicsPreferences()
        backend = nil
        controller = nil
        appliedPixels = nil
        state = .stopped
        creating = false
        // Publication deliberately leaves every existing/newer error untouched.
        let completionSelection = selectionGeneration
        let completionDraft = creationGeneration
        await refreshWindowsLaunchReadiness(for: c) { [weak self, weak owner = request.owner] in
          guard let self, let owner, self.window === owner else { return false }
          return self.creationAdmission === request && self.preparing
            && self.preparationGeneration == request.preparationGeneration
            && self.selectionGeneration == completionSelection
            && self.creationGeneration == completionDraft && self.creationWorkflowIsIdle
            && !self.creating && self.configuration == c
            && self.selectedConfigurationURL
              == destination.appendingPathComponent("configuration.json")
            && owner.attachedSheet == nil
        }
      } catch {
        // A throw may follow a real commit. No success or library authority is
        // invented, and incomplete/committed folders remain available to inspect.
        surfaceCreationFailure(
          (error as? VMError)?.errorDescription
            ?? "The VM creation could not be confirmed. Preserve its new folder and inspect it before retrying.",
          request: request)
      }
    }
  }

  func showLinuxCreation() {
    guard !isBusy, creationWorkflowIsIdle, !creating,
      let owner = window, owner.attachedSheet == nil
    else { return }
    windowsCreationResources = nil
    creating = true
  }

  var canUse120HzGraphics: Bool { (window?.screen?.maximumFramesPerSecond ?? 0) >= 120 }

  var windowsGraphicsSummary: String {
    guard acceleratedDisplayEvaluation else { return "Basic display" }
    let pixels =
      hasPrivateDisplayEvaluation
      ? displayEvaluation?.initialPixels
      : PixelSize(
        width: windowsGraphicsSettings.initialWidth, height: windowsGraphicsSettings.initialHeight)
    guard let pixels else {
      return "Accelerated graphics · experimental"
    }
    let rate = gpuRefreshEvaluation == .hz120 ? 120 : 60
    return "Requested: \(pixels.width) × \(pixels.height) at \(rate) Hz · experimental"
  }

  var canEditGraphicsSettings: Bool {
    usesWindowsDriverDisc && directory != nil && window?.attachedSheet == nil
      && window != nil && (state == .stopped || state == .failed)
      && !isBusy && !needsOwnershipRecovery && !showingLibrary && !creating
      && !hasPrivateDisplayEvaluation
  }

  func showGraphicsSettings() {
    guard canEditGraphicsSettings, let owner = window else { return }
    releaseInput()
    graphicsEditingContext = pickerContext(for: owner)
    graphicsError = nil
    loadGraphicsPreferenceSnapshot()
    editingGraphics = true
  }

  func cancelGraphicsSettings() {
    guard !preparing else { return }
    editingGraphics = false
    graphicsSettingsDismissed()
  }

  func graphicsSettingsDismissed() {
    graphicsEditingContext = nil
    graphicsPreferenceSnapshot = nil
    graphicsError = nil
  }

  private var graphicsEditorIsCurrent: Bool {
    guard editingGraphics, !preparing, !isActive, !needsOwnershipRecovery,
      state == .stopped || state == .failed,
      windowsRuntime == nil, recordedRuntime?.isBusy != true, lock == nil,
      !editingHardware, !editingNetwork, !reviewingVM, !creating, !showingLibrary,
      !trashOperationInProgress,
      let owner = window, let context = graphicsEditingContext,
      pickerContext(for: owner) == context, usesWindowsDriverDisc, !hasPrivateDisplayEvaluation
    else { return false }
    return true
  }

  var canResetRememberedGraphicsSettings: Bool {
    guard graphicsEditorIsCurrent, let snapshot = graphicsPreferenceSnapshot,
      let url = selectedConfigurationURL, let configuration
    else { return false }
    return snapshot.canReset && snapshot.matches(configurationURL: url, vmID: configuration.id)
  }

  func resetRememberedGraphicsSettings() {
    guard canResetRememberedGraphicsSettings, let snapshot = graphicsPreferenceSnapshot else {
      graphicsError = "Cancel and reopen Graphics Settings before resetting remembered settings."
      return
    }
    do {
      let reset = try graphicsPreferences.resetAll(from: snapshot)
      guard graphicsEditorIsCurrent else { throw graphicsPreferenceSelectionChanged() }
      graphicsPreferenceSnapshot = reset
      graphicsPreferencesWarning = nil
      graphicsError = nil
    } catch {
      graphicsError =
        (error as? VMError)?.errorDescription
        ?? "The remembered graphics settings could not be reset."
    }
  }

  func saveGraphicsSettings(_ settings: WindowsGraphicsSettings) {
    guard graphicsEditorIsCurrent, let owner = window,
      let url = selectedConfigurationURL, let configuration
    else {
      graphicsError = "Cancel and reopen Graphics Settings for the stopped VM."
      return
    }
    do {
      let canonical = try settings.validated(canUse120: canUse120HzGraphics)
      guard let snapshot = graphicsPreferenceSnapshot,
        snapshot.matches(configurationURL: url, vmID: configuration.id)
      else { throw graphicsPreferenceSelectionChanged() }
      let saved = try graphicsPreferences.remember(canonical, from: snapshot)
      guard graphicsEditorIsCurrent, window === owner,
        selectedConfigurationURL == url, self.configuration == configuration,
        saved.matches(configurationURL: url, vmID: configuration.id), saved.settings == canonical
      else { throw graphicsPreferenceSelectionChanged() }
      graphicsSelection = GraphicsSelection(
        configurationURL: url, vmID: configuration.id, settings: canonical)
      graphicsPreferencesWarning = nil
      editingGraphics = false
      graphicsSettingsDismissed()
      preparing = true
      Task { [self] in
        defer { preparing = false }
        await refreshWindowsLaunchReadiness(for: configuration)
      }
    } catch {
      graphicsError =
        (error as? VMError)?.errorDescription ?? "Review the graphics dimensions and refresh rate."
    }
  }

  private func graphicsPreferenceSelectionChanged() -> VMError {
    VMError(
      .staleOperation, "The remembered settings or selected VM could not be confirmed.",
      recovery: "Cancel and reopen Graphics Settings, review the settings and save again.")
  }

  private func clearGraphicsPreferenceSelection() {
    graphicsSelection = nil
    graphicsPreferenceSnapshot = nil
    graphicsPreferencesWarning = nil
  }

  private func loadGraphicsPreferenceSnapshot() {
    graphicsPreferenceSnapshot = nil
    graphicsPreferencesWarning = nil
    guard usesWindowsDriverDisc, !hasPrivateDisplayEvaluation,
      let url = selectedConfigurationURL, let configuration
    else { return }
    do {
      let snapshot = try graphicsPreferences.load(at: url, vmID: configuration.id)
      graphicsPreferenceSnapshot = snapshot
      graphicsPreferencesWarning = snapshot.issue?.message
    } catch {
      graphicsPreferencesWarning =
        "Remembered graphics settings could not be read. Cancel and reopen Graphics Settings to retry."
    }
  }

  private func restoreGraphicsPreferences() {
    graphicsSelection = nil
    loadGraphicsPreferenceSnapshot()
    guard let snapshot = graphicsPreferenceSnapshot,
      let url = selectedConfigurationURL, let configuration,
      snapshot.matches(configurationURL: url, vmID: configuration.id)
    else { return }
    graphicsSelection = GraphicsSelection(
      configurationURL: url, vmID: configuration.id, settings: snapshot.settings)
  }

  private func refreshWindowsLaunchReadiness(
    for selected: VMConfiguration, admissionIsCurrent: @MainActor () -> Bool = { true }
  ) async {
    guard admissionIsCurrent() else { return }
    windowsWorker = nil
    windowsLaunchReady = false
    windowsReadinessGeneration = nil
    windowsLaunchReadiness = .notChecked
    guard selected.guest == .windows11 else { return }
    guard selected.guest == .windows11, selected.backend == .qemuHVF,
      selected.architecture == .arm64, selected.boot == .efi,
      let url = selectedConfigurationURL
    else {
      windowsLaunchReadiness = .unavailable(.unsupportedConfiguration)
      return
    }
    let request = WindowsLaunchReadinessRequest(
      configurationURL: url, configuration: selected, profile: windowsReadinessProfile)
    windowsReadinessGeneration = request.generation
    windowsLaunchReadiness = .checking
    let result = await windowsReadinessInspection.inspect(request)
    guard admissionIsCurrent(),
      request.canApply(
        generation: windowsReadinessGeneration, selectedURL: selectedConfigurationURL,
        configuration: configuration, profile: windowsReadinessProfile,
        hasOwnedWindowsRuntime: windowsRuntime != nil)
    else {
      cancelWindowsReadinessIfOwned(request)
      return
    }
    windowsWorker = result.worker
    windowsLaunchReady = result.worker != nil
    windowsLaunchReadiness = result.readiness
  }

  /// Stale inspection may release only its own still-checking result. A newer
  /// generation, replacement selection or active/recovery runtime keeps custody.
  private func cancelWindowsReadinessIfOwned(_ request: WindowsLaunchReadinessRequest) {
    guard windowsReadinessGeneration == request.generation,
      windowsLaunchReadiness == .checking,
      selectedConfigurationURL == request.configurationURL, configuration == request.configuration,
      stoppedSettingsRuntimeIsIdle
    else { return }
    windowsReadinessGeneration = nil
    windowsLaunchReadiness = .notChecked
  }

  private var windowsReadinessProfile: WindowsLaunchReadinessRequest.Profile {
    if evaluationProducerCapture != nil { return .producerCapture }
    return acceleratedDisplayEvaluation
      ? .accelerated
      : (displayEvaluation != nil || nativeDisplayEvaluation ? .twoDimensional : .basic)
  }

  var canRecheckWindowsReadiness: Bool {
    configuration?.guest == .windows11 && directory != nil
      && (state == .stopped || state == .failed)
      && !isBusy && !needsOwnershipRecovery && windowsRuntime == nil
      && !showingLibrary && !creating && !editingHardware && !editingNetwork
  }

  func recheckWindowsReadiness() {
    guard canRecheckWindowsReadiness, let selected = configuration,
      let request = stoppedSettingsAdmission()
    else { return }
    // Claim only synchronous publication; later retries still use generation ownership.
    windowsReadinessRetryAdmissionClaimed = true
    preparing = true
    let preparation = preparationGeneration
    windowsReadinessRetryAdmissionClaimed = false
    Task { [self] in
      defer {
        if preparing && preparationGeneration == preparation { preparing = false }
      }
      // Check Again has the same weak selection binding as creation completion.
      await refreshWindowsLaunchReadiness(for: selected) { [weak self] in
        guard let self else { return false }
        return self.preparing && self.preparationGeneration == preparation
          && self.creationAdmission == nil && self.creationWorkflowIsIdle && !self.creating
          && self.stoppedSettingsAdmissionIsCurrent(request)
          && request.owner?.attachedSheet == nil
      }
    }
  }

  func showWindowsCreation() {
    guard !isBusy, !creating,
      let request = makeCreationAdmission(catalog: true)
    else { return }
    guard beginCreationPreparation(request) else { return }
    Task { [self] in
      defer { finishCreationPreparation(request) }
      guard creationAdmissionIsCurrent(request) else { return }
      do {
        // This adapter invokes the unchanged real registered-catalog factory.
        let resources = try await windowsCreationPreparation.resources()
        guard creationAdmissionIsCurrent(request) else { return }
        windowsCreationResources = resources
        creating = true
      } catch {
        surfaceCreationFailure(
          "Windows creation requires the verified development backend on Apple silicon and macOS 27 or later. Its resources could not be confirmed on this Mac.",
          request: request)
      }
    }
  }

  /// Exact current reviewed resources bind this UI request; the ordinary
  /// QemuCreationPlatform still verifies every real resource and host requirement.
  func createWindowsVM(
    _ c: VMConfiguration, in destination: URL, resources: ReviewedQemuCreationResources,
    nonce: UUID
  ) {
    guard creationDraftIsAvailable(nonce: nonce), windowsCreationResources == resources else {
      return
    }
    guard c.guest == .windows11, c.backend == .qemuHVF, c.architecture == .arm64,
      c.boot == .efi, c.network == .disconnected
    else {
      reportCreationError(
        "Choose the Windows 11 ARM64 profile and an installation image.", nonce: nonce)
      return
    }
    submitCreation(c, in: destination, resources: resources)
  }

  func chooseCopyVM() {
    guard canCopySelected, let original = configuration, let source = directory,
      let request = stoppedSettingsAdmission()
    else { return }
    releaseInput()
    // Responder/input release can synchronously replace the owner or selection.
    guard canCopySelected, stoppedSettingsAdmissionIsCurrent(request) else { return }
    copyAdmission = request
    preparing = true
    Task { [self] in
      defer {
        if copyAdmission === request {
          copyAdmission = nil
          preparing = false
        }
      }
      // Recheck after the queued Task enters, before any native presentation.
      guard copyAdmissionIsCurrent(request) else { return }
      let chosenName = await copyPresentation.name(for: original, on: request.owner)
      guard copyAdmissionIsCurrent(request), await waitForCopySheetDetachment(request)
      else { return }
      guard let chosenName else { return }
      let name = chosenName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard ConfigurationValidator.isSafeComponent(name), name.utf8.count <= 128,
        !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        surfaceStoppedSettingsError(
          "Choose a copy name with 1–128 UTF-8 bytes and no path separators.",
          editorPresented: false)
        return
      }
      let parent = await copyPresentation.parentDirectory(for: source, on: request.owner)
      guard copyAdmissionIsCurrent(request), await waitForCopySheetDetachment(request)
      else { return }
      guard let parent else { return }
      let destination = parent.appendingPathComponent(name + ".macopenvm", isDirectory: true)
      await copyVM(
        from: source, to: destination, name: name, expected: original, request: request)
    }
  }

  private func copyAdmissionIsCurrent(_ request: DesktopStoppedSettingsAdmission) -> Bool {
    preparing && copyAdmission === request && stoppedSettingsAdmissionIsCurrent(request)
      && stoppedSettingsRuntimeIsIdle && state == .stopped && !showingLibrary && !creating
      && !editingHardware && !editingDiskCapacity && !editingNetwork && !editingGraphics
      && !reviewingVM && !trashOperationInProgress && pendingLibrarySelection == nil
      && pendingLibraryNavigation == nil
  }

  private func waitForCopySheetDetachment(_ request: DesktopStoppedSettingsAdmission) async -> Bool
  {
    let deadline = ContinuousClock.now + .seconds(1)
    while copyAdmissionIsCurrent(request), request.owner?.attachedSheet != nil,
      ContinuousClock.now < deadline
    {
      try? await Task.sleep(for: .milliseconds(20))
    }
    return copyAdmissionIsCurrent(request) && request.owner?.attachedSheet == nil
  }

  private func supportReportExportIsCurrent(_ request: DesktopSupportReportExportAdmission) -> Bool
  {
    guard supportReportExportAdmission === request, preparing,
      preparationGeneration == request.preparationGeneration,
      supportReportExportWorkflowIsAvailable, selectionGeneration == request.selectionGeneration,
      let owner = request.owner, window === owner
    else { return false }
    return pickerContext(for: owner) == request.context
  }

  private func finishSupportReportExport(_ request: DesktopSupportReportExportAdmission) {
    guard supportReportExportAdmission === request else { return }
    supportReportExportAdmission = nil
    if preparing && preparationGeneration == request.preparationGeneration { preparing = false }
  }

  func exportSupportReport() {
    guard canExportSupportReport, let owner = window, owner.attachedSheet == nil else { return }
    let request = DesktopSupportReportExportAdmission(
      owner: owner, context: pickerContext(for: owner), selectionGeneration: selectionGeneration,
      errorGeneration: errorGeneration)
    // Claim before either @Published or responder/input release can synchronously reenter.
    supportReportExportAdmission = request
    preparing = true
    request.preparationGeneration = preparationGeneration
    guard supportReportExportIsCurrent(request), owner.attachedSheet == nil else {
      finishSupportReportExport(request)
      return
    }
    releaseInput()
    guard supportReportExportIsCurrent(request), owner.attachedSheet == nil else {
      finishSupportReportExport(request)
      return
    }
    let source = directory
    let probe = HostProbe.capture()
    let host = DiagnosticHostFacts(
      virtualizationSupported: probe.virtualizationSupported,
      virtualizationEntitled: probe.virtualizationEntitled)
    supportReportExport.chooseDestination(
      on: owner,
      willPresent: { [weak self] in
        guard let self else { return false }
        guard self.supportReportExportIsCurrent(request), owner.attachedSheet == nil else {
          self.finishSupportReportExport(request)
          return false
        }
        return true
      },
      selected: { [weak self] destination in
        guard let self, self.supportReportExportAdmission === request,
          request.waitingForDestination
        else { return }
        // A replayed cancellation or selection cannot release or duplicate accepted work.
        request.waitingForDestination = false
        guard self.supportReportExportIsCurrent(request), let destination else {
          self.finishSupportReportExport(request)
          return
        }
        Task { [self] in
          defer { finishSupportReportExport(request) }
          guard supportReportExportIsCurrent(request) else { return }
          do {
            try await supportReportExport.makeAndExport(
              directory: source, host: host, to: destination)
          } catch {
            if supportReportExportIsCurrent(request), errorGeneration == request.errorGeneration {
              show(error)
            }
          }
        }
      })
  }

  private func copyVM(
    from source: URL, to destination: URL, name: String, expected original: VMConfiguration,
    request: DesktopStoppedSettingsAdmission
  ) async {
    guard copyAdmissionIsCurrent(request), request.owner?.attachedSheet == nil else { return }
    do {
      let result = try await vmCopy.copy(
        from: source, to: destination, name: name, expected: original)
      // The completed Core transaction is preserved and discoverable even when
      // its UI request becomes stale. Never roll back or delete the new copy.
      library.remember(
        result.configuration, at: destination.appendingPathComponent("configuration.json"))
      if library.errorMessage != nil {
        surfaceStoppedSettingsError(
          "The copy was created, but its library entry could not be saved. Preserve the new folder and open it for inspection.",
          editorPresented: false)
      }
      guard copyAdmissionIsCurrent(request) else {
        surfaceStoppedSettingsError(
          "The copy was created. Open its new folder from the VM library.", editorPresented: false)
        return
      }
      configuration = result.configuration
      directory = destination
      restoreGraphicsPreferences()
      backend = nil
      controller = nil
      appliedPixels = nil
      state = .stopped
    } catch {
      surfaceStoppedSettingsError(
        (error as? VMError)?.errorDescription
          ?? "The VM copy could not be confirmed. Preserve its new folder and reopen it before retrying.",
        editorPresented: false)
    }
  }

  func chooseVM() {
    guard !isBusy, !showingLibrary, !needsOwnershipRecovery, !creating else { return }
    guard let owner = window else {
      show(
        VMError(
          .invalidTransition, "The VM window is not ready.",
          recovery: "Reopen macOpenVM and try again.")
      )
      return
    }
    guard canRequestLibraryNavigation else { return }
    let panel = NSOpenPanel()
    panel.title = "Open a virtual machine"
    panel.message = "Choose the VM folder or its configuration.json file."
    panel.allowedContentTypes = [.json, .folder]
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.treatsFilePackagesAsDirectories = true
    panel.showsHiddenFiles = true
    beginSelectionPanel(panel, on: owner) { [weak self] in self?.openVMLocation($0) }
  }

  func openVMLocation(_ selected: URL, activateWindow: Bool = true) {
    guard !isBusy, !showingLibrary, !needsOwnershipRecovery, !creating,
      let owner = window, owner.attachedSheet == nil
    else { return }
    let request = VMLibraryOpeningRequest(
      owner: owner, context: pickerContext(for: owner),
      selectionGeneration: selectionGeneration)
    do { try VMLibraryOpenLocation.validateLocation(selected) } catch {
      show(error)
      return
    }
    preparing = true
    Task { [self] in
      let status = await files.status(at: selected)
      preparing = false
      guard !isBusy, let currentOwner = request.owner, window === currentOwner,
        pickerContext(for: currentOwner) == request.context,
        selectionGeneration == request.selectionGeneration, !showingLibrary, !creating,
        !needsOwnershipRecovery
      else { return }
      do {
        let registration = try VMLibraryOpenLocation.registration(for: selected, kind: status.kind)
        // The existing selection path now owns preparation and identity admission.
        selectVM(at: registration, opening: request, activateWindow: activateWindow)
      } catch {
        preparing = false
        show(error)
      }
    }
  }

  /// The opt-in qualification driver uses the ordinary selection/readiness path
  /// without requesting foreground focus or substituting a worker provider.
  func qualificationSelectVM(at url: URL, expectedID: UUID) async throws {
    guard !isBusy, !showingLibrary, !creating else {
      throw VMError(.busy, "The VM selection is busy.", recovery: "Preserve its current session.")
    }
    selectVM(at: url, expectedID: expectedID, activateWindow: false)
    while preparing { try await Task.sleep(for: .milliseconds(25)) }
    guard configuration?.id == expectedID, selectedConfigurationURL == url else {
      throw VMError(
        .staleOperation, "The requested VM selection was not confirmed.",
        recovery: "Preserve the current selection and review its configuration.")
    }
  }

  private func selectVM(
    at url: URL, expectedID: UUID? = nil, destination: LibraryDestination = .open,
    networkSelection: LibraryNetworkSelection? = nil,
    reviewSelection: LibraryReviewSelection? = nil,
    opening: VMLibraryOpeningRequest? = nil, activateWindow: Bool = true
  ) {
    guard !isBusy else { return }
    let opening =
      opening
      ?? (activateWindow
        ? window.map {
          VMLibraryOpeningRequest(
            owner: $0, context: pickerContext(for: $0),
            selectionGeneration: selectionGeneration)
        } : nil)
    if destination == .review {
      guard let request = reviewSelection, request.entry.configurationURL == url,
        request.entry.vmID == expectedID, libraryReviewSelectionIsCurrent(request)
      else { return }
    }
    let selectionErrorGeneration = errorGeneration
    networkSharedPermission = nil
    preparing = true
    Task { [self] in
      do {
        let observation = try await selectionInspector.inspect(at: url, expectedID: expectedID)
        let c = observation.configuration
        let selectedDirectory = url.deletingLastPathComponent()
        let report = observation.report
        if let opening {
          guard let owner = opening.owner, window === owner,
            pickerContext(for: owner) == opening.context,
            selectionGeneration == opening.selectionGeneration,
            !showingLibrary, !creating
          else {
            preparing = false
            return
          }
        }
        if let request = networkSelection {
          guard libraryNetworkOwnerIsCurrent(request),
            libraryNetworkPresentation.isDetached(on: window),
            !showingLibrary, !creating, state == .stopped, library.entries.contains(request.entry)
          else {
            preparing = false
            return
          }
        }
        if destination == .review {
          let checked = try await VMLibrarySelection.readForEditing(
            at: url, expectedID: expectedID, files: files)
          guard checked == c else {
            throw VMError(
              .staleOperation, "The saved VM changed before review.",
              recovery: "Preserve its files and select its configuration again.")
          }
          guard let request = reviewSelection, libraryReviewSelectionIsCurrent(request) else {
            preparing = false
            return
          }
        }
        directory = selectedDirectory
        configuration = c
        let committedReviewGeneration = vmReviewGeneration
        restoreGraphicsPreferences()
        backend = nil
        controller = nil
        state = .stopped
        if errorGeneration == selectionErrorGeneration { errorMessage = nil }
        library.remember(c, at: url)
        if self.configuration == c, selectedConfigurationURL == url {
          openHistoryAdvice =
            destination == .review
            ? nil : VMOpenHistoryAdvice(configuration: c, at: url, history: report.history)
        }
        let selectedOpeningContext = opening == nil ? nil : window.map { pickerContext(for: $0) }
        let selectedOpeningGeneration = selectionGeneration
        await refreshWindowsLaunchReadiness(for: c)
        preparing = false
        if let opening {
          guard let owner = opening.owner, window === owner,
            selectedOpeningContext == pickerContext(for: owner),
            selectionGeneration == selectedOpeningGeneration, configuration == c,
            selectedConfigurationURL == url,
            !showingLibrary, !creating
          else { return }
        }
        if destination == .review {
          guard let request = reviewSelection, let owner = request.owner, window === owner,
            ObjectIdentifier(owner) == request.previous.owner,
            vmReviewGeneration == committedReviewGeneration,
            configuration == c, selectedConfigurationURL == url,
            library.entries.contains(where: { $0.configurationURL == url && $0.vmID == c.id }),
            canReviewSelectedVM
          else { return }
          showVMReview()
        } else if errorMessage == nil {
          switch destination {
          case .open, .review: break
          case .hardware: showHardwareSettings()
          case .network:
            guard let request = networkSelection, libraryNetworkOwnerIsCurrent(request),
              libraryNetworkPresentation.isDetached(on: window),
              self.configuration == c, selectedConfigurationURL == url,
              library.entries.contains(where: { $0.configurationURL == url && $0.vmID == c.id })
            else { return }
            showNetworkSettings()
          }
        }
        if activateWindow { window?.makeKeyAndOrderFront(nil) }
      } catch {
        preparing = false
        if destination == .review {
          guard let request = reviewSelection, libraryReviewSelectionIsCurrent(request) else {
            return
          }
        }
        if let opening {
          guard let owner = opening.owner, window === owner,
            pickerContext(for: owner) == opening.context,
            selectionGeneration == opening.selectionGeneration
          else { return }
        }
        if errorGeneration == selectionErrorGeneration { show(error) }
      }
    }
  }

  private func startWindows(_ selected: VMConfiguration, in directory: URL) {
    guard canStartSelected, !isBusy, let worker = windowsWorker else { return }
    let requestedDisplay: ReviewedQemu2DDisplay?
    let acceleratedDisplay: ReviewedQemuAcceleratedDisplay?
    do {
      // GPU trials carry explicitly measured, bounded initial dimensions.
      // Measuring the library here substitutes its smaller window before the
      // guest enters fullscreen. Live matching still measures the guest view.
      if !hasPrivateDisplayEvaluation {
        requestedDisplay = try windowsGraphicsSettings.reviewedInitialDisplay(
          hostMaximumFramesPerSecond: window?.screen?.maximumFramesPerSecond)
      } else if nativeDisplayEvaluation && !acceleratedDisplayEvaluation {
        guard let window, let content = window.contentView,
          let pixels = GuestBackingGeometry.pixels(
            forBackingBounds: content.convertToBacking(
              content.convert(window.contentLayoutRect, from: nil)))
        else {
          throw VMError(
            .invalidConfiguration, "The native VM viewport is unavailable.",
            recovery: "Open the VM window and try again.")
        }
        requestedDisplay = try ReviewedQemu2DDisplay(initialPixels: pixels)
      } else {
        requestedDisplay = displayEvaluation
      }
      if acceleratedDisplayEvaluation {
        guard let pixels = requestedDisplay?.initialPixels else {
          throw VMError(
            .invalidConfiguration, "The GPU viewport dimensions are unavailable.",
            recovery: "Open the VM window and try again.")
        }
        if gpuRefreshEvaluation == .hz120 {
          guard let maximum = window?.screen?.maximumFramesPerSecond, maximum >= 120 else {
            throw VMError(
              .invalidConfiguration, "The selected Mac display does not provide 120 Hz.",
              recovery: "Move the VM to the 120 Hz display before starting the trial.")
          }
        }
        acceleratedDisplay = try ReviewedQemuAcceleratedDisplay(
          initialPixels: pixels, separateFirmware: true, hostWindow: .fourGiB,
          refreshRate: gpuRefreshEvaluation)
      } else {
        acceleratedDisplay = nil
      }
    } catch {
      show(error)
      return
    }
    preparing = true
    let runtime = DesktopWindowsRuntime(
      configuration: selected, directory: directory, worker: worker,
      displayEvaluation: acceleratedDisplayEvaluation ? nil : requestedDisplay,
      acceleratedDisplay: acceleratedDisplay, producerCapture: evaluationProducerCapture)
    // Store the actual parent lifetime before its first launch suspension.
    windowsRuntime = runtime
    runtime.onStateChange = { [weak self, weak runtime] state in
      guard let self, let runtime, self.windowsRuntime === runtime else { return }
      self.state = state
      self.windowsDisplay?.runtimeStateChanged(state)
    }
    runtime.onChange = { [weak self, weak runtime] in
      guard let self, let runtime, self.windowsRuntime === runtime else { return }
      self.objectWillChange.send()
    }
    runtime.onError = { [weak self, weak runtime] error in
      guard let self, let runtime, self.windowsRuntime === runtime else { return }
      self.show(error)
    }
    runtime.onSettled = { [weak self, weak runtime] result in
      guard let self, let runtime, self.windowsRuntime === runtime else { return }
      Task { @MainActor [self, runtime] in
        let display = windowsDisplay
        display?.releaseInput()
        await display?.disconnectDisplay()
        guard windowsRuntime === runtime else { return }
        windowsDisplay = nil
        windowsRuntime = nil
        state = result.failed ? .failed : .stopped
        if result.failed {
          show(
            runtime.lastFailure
              ?? VMError(
                .storage, "The Windows run ended with a failed result.",
                recovery: "Preserve its records and inspect the VM before starting it again."))
        } else if result.outcome == .forcedStopped {
          errorMessage = "The VM was force stopped. Review guest recovery before its next start."
        }
      }
    }
    Task { [self, runtime] in
      defer { preparing = false }
      do {
        try await runtime.launch()
        guard windowsRuntime === runtime, runtime.phase == .running,
          let context = runtime.displayContext
        else { return }
        windowsDisplay = try RfbLabSession(
          registeredContext: context,
          currentLaunchGeneration: { [weak self, weak runtime] in
            guard let self, let runtime, self.windowsRuntime === runtime,
              runtime.phase == .running
            else { return nil }
            return runtime.launchGeneration
          },
          displayConsoleSelection: requestedDisplay != nil
            && (acceleratedDisplay == nil || acceleratedDisplay?.separateFirmware == true),
          nativeResolutionEvaluation: acceleratedDisplay != nil)
        showingLibrary = false
        errorMessage = nil
      } catch {
        if windowsRuntime === runtime, runtime.phase == .settled {
          windowsRuntime = nil
          state = .failed
          windowsWorker = nil
          windowsLaunchReady = false
          windowsReadinessGeneration = nil
          windowsLaunchReadiness = .notChecked
        }
        show(error)
      }
    }
  }

  func start() {
    guard canRequestStart, let selected = configuration, let directory,
      let content = window?.contentView
    else { return }
    if selected.guest == .windows11 && selected.backend == .qemuHVF {
      startWindows(selected, in: directory)
      return
    }
    preparing = true
    let pixels = content.convertToBacking(content.bounds).size
    let size = PixelSize(width: Int(pixels.width.rounded()), height: Int(pixels.height.rounded()))
    Task { [self] in
      defer { preparing = false }
      do {
        let registration = directory.appendingPathComponent("configuration.json")
        let observed = try await VMLibrarySelection.read(
          at: registration, expectedID: selected.id, files: files)
        lock = try VMLock(directory: directory, expectedVMID: observed.id)
        guard let lock else {
          throw VMError(
            .storage, "Writer ownership is unavailable.",
            recovery: "Preserve files and retry after inspection.")
        }
        let c = try ConfigurationCodec.decode(
          await files.readMetadata(at: registration, limit: ConfigurationCodec.maximumBytes))
        guard c.id == observed.id, lock.owns(directory) else {
          throw VMError(
            .busy, "The saved VM identity changed before writer admission.",
            recovery:
              "Preserve the current configuration and reopen read-only inspection before retrying.")
        }
        try ConfigurationValidator.validate(c, host: .current)
        guard c.backend == .appleVz, c.guest == .linux else {
          throw VMError(
            .unsupported, "This guest and backend combination is unavailable.",
            recovery:
              "Reopen the saved VM in the library and check its settings. Windows 11 requires the reviewed Windows runtime; Linux uses Apple Virtualization."
          )
        }
        let usage = try await files.inspectWritableFile(
          at: directory.appendingPathComponent(c.diskFile))
        guard usage.virtualBytes == c.diskBytes else {
          throw VMError(
            .corruptMetadata, "Disk size differs from configuration.",
            recovery: "Inspect the VM without changing it.")
        }
        if c.boot == .efi {
          _ = try await files.inspectWritableFile(
            at: directory.appendingPathComponent("efi-variables.bin"))
        }
        if let support = c.supportMedia {
          _ = try await files.inspectReadOnlyImage(at: URL(fileURLWithPath: support))
        }
        let identity = try await files.readMetadata(
          at: directory.appendingPathComponent("machine-identity.bin"), limit: 4096)
        let machine = try AppleVirtualMachine(
          configuration: c, directory: directory, identityData: identity, display: size)
        let runtime = DesktopRecordedRuntime(lock: lock, backend: machine)
        // Store custody before the first metadata suspension. A failed preparation
        // must not drop its real lease merely because no controller was returned.
        recordedRuntime = runtime
        runtime.onStateChange = { [weak self, weak runtime] state in
          guard let self, let runtime, self.recordedRuntime === runtime else { return }
          self.state = state
        }
        runtime.onError = { [weak self, weak runtime] error in
          guard let self, let runtime, self.recordedRuntime === runtime else { return }
          self.show(error)
        }
        runtime.onSettled = { [weak self, weak runtime] in
          guard let self, let runtime, self.recordedRuntime === runtime,
            runtime.phase == .settled
          else { return }
          self.releaseInput()
          NSCursor.arrow.set()
          self.controller = nil
          self.backend = nil
          self.recordedRuntime = nil
          self.lock = nil
        }
        try await runtime.prepare(in: directory, vmID: c.id, files: files)
        // The native rendering handle can first be exposed only after binding.
        configuration = c
        controller = runtime.controller
        backend = machine
        inputCaptured = true
        appliedPixels = nil
        try await runtime.perform(.start)
      } catch {
        if recordedRuntime == nil, !isActive, controller == nil { lock = nil }
        show(error)
      }
    }
  }

  func perform(_ operation: LifecycleOperation) {
    if let runtime = windowsRuntime {
      Task { [self, runtime] in
        guard windowsRuntime === runtime else { return }
        windowsDisplay?.suspendForLifecycleTransition()
        defer {
          if windowsRuntime === runtime { windowsDisplay?.runtimeStateChanged(runtime.state) }
        }
        do { try await runtime.perform(operation) } catch {
          guard windowsRuntime === runtime else { return }
          show(error)
        }
      }
      return
    }
    guard let runtime = recordedRuntime else { return }
    Task { [self, runtime] in
      guard recordedRuntime === runtime else { return }
      do { try await runtime.perform(operation) } catch {
        guard recordedRuntime === runtime else { return }
        show(error)
      }
    }
  }
  func attachGuestView(_ view: VZVirtualMachineView) {
    guard let owner = view.window else {
      if guestView === view { guestView = nil }
      return
    }
    guestView = view
    window = owner
    if inputCaptured { captureInput() }
  }
  func captureInput() {
    if let display = windowsDisplay {
      display.captureInput()
      return
    }
    guard isActive, let view = guestView, let owner = window,
      view.window === owner, owner.attachedSheet == nil
    else { return }
    owner.makeKeyAndOrderFront(nil)
    guard owner.makeFirstResponder(view) else {
      show(
        VMError(
          .invalidTransition, "The guest display could not receive keyboard focus.",
          recovery: "Bring the VM window forward and try Input → Capture Input again."))
      return
    }
    view.capturesSystemKeys = true
    inputCaptured = true
  }
  func suspendInputForFocusLoss() {
    if let display = windowsDisplay {
      display.suspendInput()
    } else {
      guestView?.capturesSystemKeys = false
      inputCaptured = false
    }
  }

  func releaseInput() {
    windowsDisplay?.releaseInput()
    GuestHostPointerCapture.shared.retryPendingRestoration()
    guestView?.capturesSystemKeys = false
    inputCaptured = false
    window?.makeFirstResponder(nil)
  }
  func confirmForceStop() {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Force stop this guest?"
    alert.informativeText = "Unsaved guest data may be lost. A clean guest shutdown is safer."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Force Stop")
    if alert.runModal() == .alertSecondButtonReturn { perform(.forceStop) }
  }
  func enteringFullscreen() {
    guard windowsRuntime == nil, let application: NSApplication = NSApp else { return }
    presentation.beginTransition(application.presentationOptions)
    menuBarVisibility.prepare()
  }
  func enteredFullscreen() {
    fullscreen = true
    guard windowsRuntime == nil, let application: NSApplication = NSApp else { return }
    presentation.prepare(application.presentationOptions)
    menuBarVisibility.prepare()
    refreshFullscreenPresentation()
  }
  func refreshFullscreenPresentation() {
    guard windowsRuntime == nil, let application: NSApplication = NSApp else { return }
    let current = application.presentationOptions
    let effective = application.currentSystemPresentationOptions
    let active =
      isActive && application.isActive && window?.isKeyWindow == true
      && window?.styleMask.contains(.fullScreen) == true
    let desired =
      active ? presentation.applying(to: effective) : presentation.suspending(current)
    if desired != current || (active && desired != effective) {
      application.presentationOptions = desired
    }
    if active {
      menuBarVisibility.show(activeOwner: true)
    } else {
      menuBarVisibility.suspend(canChangeVisibility: application.isActive)
    }
  }
  func leavingFullscreen() {
    fullscreen = false
    guard windowsRuntime == nil, let application: NSApplication = NSApp else { return }
    let current = application.presentationOptions
    let desired = presentation.finish(current)
    if desired != current { application.presentationOptions = desired }
    menuBarVisibility.finish(canChangeVisibility: application.isActive)
  }
  private func show(_ error: Error) {
    errorMessage =
      (error as? VMError)?.errorDescription
      ?? "VM operation failed. Preserve its files and review host capabilities."
  }
}

private struct DesktopView: View {
  @ObservedObject var session: DesktopSession
  var body: some View {
    Group {
      if let backend = session.backend, session.isActive {
        GuestSurface(
          backend: backend, captured: session.inputCaptured,
          onApplied: { session.appliedPixels = $0 }, onAttachment: session.attachGuestView
        )
        .accessibilityLabel("\(session.configuration?.name ?? "Linux") guest display")
        .ignoresSafeArea(
          .container, edges: session.fullscreen ? [] : .top
        )
        .background(GuestWindowChrome())
      } else if let display = session.windowsDisplay {
        RfbLabDesktopView(
          session: display, guestName: session.configuration?.name,
          waitingForWindowsShutdown: session.isWaitingForWindowsShutdown)
      } else if session.creating {
        if let resources = session.windowsCreationResources {
          WindowsCreationView(session: session, resources: resources).id(session.creationDraftNonce)
        } else {
          LinuxCreationView(session: session).id(session.creationDraftNonce)
        }
      } else {
        workspace
      }
    }
    .navigationTitle("macOpenVM")
    .navigationSubtitle(
      session.creating
        ? (session.windowsCreationResources == nil ? "New Linux VM" : "New Windows VM")
        : session.configuration?.name ?? "Virtual machines"
    )
    .toolbar(.hidden, for: .windowToolbar)
    .modifier(OwningWindowDismissPolicy(session: session))
    .background(WindowAnchor(onWindow: { if let window = $0 { session.window = window } }))
    .sheet(
      isPresented: $session.editingHardware, onDismiss: session.hardwareSettingsDismissed
    ) {
      if let configuration = session.hardwareConfiguration {
        HardwareSettingsView(session: session, configuration: configuration)
      }
    }
    .sheet(
      isPresented: $session.editingDiskCapacity, onDismiss: session.diskCapacitySettingsDismissed
    ) {
      Group {
        if session.showingDiskMetadataUpgrade, let nonce = session.diskMetadataDraftNonce {
          DiskMetadataUpgradeView(
            session: session, nonce: nonce, check: session.diskMetadataCheckGeneration)
        } else if let configuration = session.diskCapacityConfiguration {
          DiskCapacitySettingsView(session: session, configuration: configuration)
            .id(session.diskCapacityDraftNonce)
        }
      }
      .background(WindowAnchor(onWindow: session.registerDiskCapacityWindow))
    }
    .sheet(isPresented: $session.editingNetwork, onDismiss: session.networkSettingsDismissed) {
      if let configuration = session.networkConfiguration {
        NetworkSettingsView(
          session: session, configuration: configuration,
          sharedPermission: session.networkSharedPermission)
      }
    }
    .sheet(isPresented: $session.editingGraphics, onDismiss: session.graphicsSettingsDismissed) {
      WindowsGraphicsSettingsView(
        settings: session.windowsGraphicsSettings, canUse120: session.canUse120HzGraphics,
        isSaving: session.preparing, error: session.graphicsError,
        preferenceWarning: session.graphicsPreferencesWarning,
        canResetRememberedSettings: session.canResetRememberedGraphicsSettings,
        resetRememberedSettings: session.resetRememberedGraphicsSettings,
        save: session.saveGraphicsSettings, cancel: session.cancelGraphicsSettings
      )
      .interactiveDismissDisabled(session.preparing)
    }
    .sheet(isPresented: $session.reviewingVM, onDismiss: session.vmReviewDismissed) {
      if let context = session.vmReview.context {
        VMReviewView(
          review: session.vmReview, context: context,
          operationErrorPending: session.errorMessage != nil,
          canRefresh: { session.canRefreshVMReview }, refresh: session.refreshVMReview,
          done: session.closeVMReview
        )
        .background(WindowAnchor(onWindow: session.registerVMReviewWindow))
      }
    }
    .sheet(isPresented: $session.showingLibrary, onDismiss: session.libraryDismissed) {
      VMLibraryView(session: session, library: session.library)
    }
    .alert(
      "macOpenVM",
      isPresented: Binding(
        get: { session.errorMessage != nil && session.canPresentOperationError },
        set: { if !$0 && session.canPresentOperationError { session.errorMessage = nil } })
    ) {
      Button("OK") { session.errorMessage = nil }
    } message: {
      Text(session.errorMessage ?? "")
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification))
    { notification in
      guard notification.object as? NSWindow === session.window else { return }
      session.enteringFullscreen()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) {
      notification in
      guard notification.object as? NSWindow === session.window else { return }
      session.enteredFullscreen()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) {
      notification in
      guard notification.object as? NSWindow === session.window else { return }
      session.leavingFullscreen()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
      notification in
      guard notification.object as? NSWindow === session.window else { return }
      session.closeVMReview()
      session.leavingFullscreen()
      session.releaseInput()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
      notification in
      guard notification.object as? NSWindow === session.window else { return }
      session.suspendInputForFocusLoss()
      session.refreshFullscreenPresentation()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
      notification in
      guard notification.object as? NSWindow === session.window else { return }
      session.installLegacyWindowCloseGuard()
      session.windowsDisplay?.focusChanged()
      session.refreshFullscreenPresentation()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification))
    { _ in
      session.suspendInputForFocusLoss()
      session.refreshFullscreenPresentation()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      session.windowsDisplay?.focusChanged()
      session.refreshFullscreenPresentation()
    }
  }

  private var workspace: some View {
    VMGlassGroup {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
              Text("Your virtual machines")
                .font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
              Text("Create or open a VM, then continue in its own guest display.")
                .font(.callout).vmSupportingText()
            }
            Spacer(minLength: 0)
            VMGlassBadge(title: "Experimental", symbol: "flask")
          }
          if let configuration = session.configuration {
            VMOpenHistoryAdviceView(
              advice: session.currentOpenHistoryAdvice, dismiss: session.dismissOpenHistoryAdvice)
            selectedMachine(configuration)
          } else {
            SavedVMLibrarySummary(
              library: session.library, canOpen: session.canShowLibrary, open: session.showLibrary)
            VMContentCard {
              Label("Choose an ARM64 installation image", systemImage: "desktopcomputer")
                .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
              Text(
                "Choose your installation image and a new destination. Hardware defaults leave room for your Mac, and networking starts disconnected."
              )
              .font(.callout).vmSupportingText()
              HStack(spacing: 12) {
                Button("New Windows VM…", systemImage: "plus", action: session.showWindowsCreation)
                  .vmGlassControl(prominent: true).disabled(session.isBusy)
                Button("New Linux VM…", systemImage: "plus", action: session.showLinuxCreation)
                  .vmGlassControl().disabled(session.isBusy)
                Button("Open VM…", systemImage: "folder", action: session.chooseVM)
                  .vmGlassControl().disabled(session.isBusy)
              }
            }
          }
          VMContentCard("On this Mac") {
            Label("Windows 11 ARM64 · primary target", systemImage: "desktopcomputer")
              .font(.callout.weight(.medium))
            Text(
              "Windows VM creation and startup use the verified development backend on macOS 27 or later. Guided installation remains experimental."
            )
            .font(.callout).vmSupportingText()
            Divider()
            Label("ARM64 Linux · native virtualization", systemImage: "cpu")
              .font(.callout.weight(.medium))
            Text(session.capabilitySummary).font(.callout).vmSupportingText()
            Text("Supply your own installation image. No operating-system media is bundled.")
              .font(.callout).vmSupportingText()
          }
        }
        .frame(maxWidth: 780, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .center)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func selectedMachine(_ configuration: VMConfiguration) -> some View {
    VMContentCard {
      HStack(alignment: .top, spacing: 18) {
        Image(systemName: "desktopcomputer")
          .font(.system(size: 32, weight: .medium)).foregroundStyle(Color.accentColor)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          Text(configuration.name).font(.title2.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
          Text("Selected VM").font(.callout).vmSupportingText()
        }
        Spacer(minLength: 0)
        VMGlassBadge(
          title: session.isBusy
            ? "Finishing operation" : session.state == .failed ? "Needs attention" : "Selected",
          symbol: session.isBusy
            ? "hourglass" : session.state == .failed ? "exclamationmark.circle" : "checkmark.circle"
        )
      }
      HStack(spacing: 28) {
        machineMetric("CPUs", value: "\(configuration.cpuCount)")
        machineMetric(
          "Memory",
          value: configuration.memoryBytes % 1_073_741_824 == 0
            ? "\(configuration.memoryBytes / 1_073_741_824) GiB"
            : "\(configuration.memoryBytes / 1_048_576) MiB")
        machineMetric("Disk capacity", value: "\(configuration.diskBytes / 1_073_741_824) GiB")
      }
      Divider()
      if !SavedVMStartEligibility.permits(configuration) {
        Label(
          "This Mac cannot start the saved configuration. Review Hardware Settings and this Mac’s capabilities before starting.",
          systemImage: "exclamationmark.triangle"
        )
        .font(.callout).fixedSize(horizontal: false, vertical: true)
      }
      LabeledContent("Networking") {
        Text(configuration.network == .shared ? "Shared · experimental" : "Disconnected")
      }.font(.callout)
      LabeledContent("Installation image") {
        Text(
          configuration.installationMedia.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "Detached"
        )
        .lineLimit(1).truncationMode(.middle)
        .help(configuration.installationMedia ?? "No installation image is attached")
      }.font(.callout)
      LabeledContent(
        session.usesWindowsDriverDisc
          ? "Windows driver disc · experimental" : "Tools image · experimental"
      ) {
        Text(
          configuration.supportMedia.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "Detached"
        )
        .lineLimit(1).truncationMode(.middle)
        .help(configuration.supportMedia ?? "No tools image is attached")
      }.font(.callout)
      HStack(spacing: 12) {
        Button("Review…", systemImage: "doc.text.magnifyingglass", action: session.showVMReview)
          .vmGlassControl().disabled(!session.canReviewSelectedVM)
          .accessibilityLabel("Review selected VM files and recorded metadata")
      }
      HStack(spacing: 12) {
        Button("Start VM", systemImage: "play.fill", action: session.start)
          .vmGlassControl(prominent: true).keyboardShortcut(.return)
          .disabled(!session.canRequestStart)
        Button(
          configuration.installationMedia == nil ? "Attach Image…" : "Change Image…",
          systemImage: "opticaldisc", action: session.chooseInstallationMedia
        )
        .vmGlassControl().disabled(session.isBusy)
        .accessibilityLabel("Choose an installation image")
        if configuration.installationMedia != nil {
          Button("Detach", systemImage: "eject") { session.changeInstallationMedia(nil) }
            .vmGlassControl().disabled(session.isBusy)
            .accessibilityLabel("Detach the installation image")
        }
      }
      if configuration.guest == .windows11 {
        WindowsReadinessView(
          readiness: session.windowsLaunchReadiness,
          canRecheck: session.canRecheckWindowsReadiness,
          recheck: session.recheckWindowsReadiness)
        HStack(spacing: 12) {
          Button("Graphics…", systemImage: "display", action: session.showGraphicsSettings)
            .vmGlassControl().disabled(!session.canEditGraphicsSettings)
            .accessibilityLabel("Windows graphics settings")
          Text(session.windowsGraphicsSummary).font(.callout).vmSupportingText()
            .fixedSize(horizontal: false, vertical: true)
        }
        if let warning = session.graphicsPreferencesWarning {
          Label(warning, systemImage: "exclamationmark.triangle")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Remembered graphics settings: \(warning)")
        }
      } else if !session.canStartSelected && SavedVMStartEligibility.permits(configuration) {
        Text(
          "Hardware settings are available. Starting this VM through the library is still pending backend verification."
        )
        .font(.callout).vmSupportingText()
      }
      HStack(spacing: 12) {
        Button(
          "Disk Capacity…", systemImage: "externaldrive", action: session.showDiskCapacitySettings
        )
        .vmGlassControl().disabled(!session.canEditDiskCapacity)
        .accessibilityLabel("Expand disk capacity, experimental")
        Text("Expand the virtual disk while this VM is stopped.")
          .font(.callout).vmSupportingText().fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 12) {
        Button("Hardware…", systemImage: "cpu", action: session.showHardwareSettings)
          .vmGlassControl().disabled(session.isBusy)
          .accessibilityLabel("Hardware settings")
        Button("Copy VM… · Experimental", systemImage: "doc.on.doc", action: session.chooseCopyVM)
          .vmGlassControl().disabled(!session.canCopySelected)
          .help("Copy a stopped native Linux VM. The new copy starts disconnected.")
        Button(
          session.usesWindowsDriverDisc
            ? "Attach Driver Disc · Experimental"
            : configuration.supportMedia == nil ? "Attach Tools…" : "Change Tools…",
          systemImage: "opticaldisc", action: session.chooseSupportMedia
        )
        .vmGlassControl().disabled(session.isBusy)
        .accessibilityLabel(
          session.usesWindowsDriverDisc
            ? "Attach the reviewed Windows driver disc, experimental" : "Choose a tools image")
        if configuration.supportMedia != nil {
          Button(
            session.usesWindowsDriverDisc ? "Detach Driver Disc" : "Detach Tools",
            systemImage: "eject"
          ) {
            session.changeSupportMedia(nil)
          }
          .vmGlassControl().disabled(session.isBusy)
          .accessibilityLabel(
            session.usesWindowsDriverDisc
              ? "Detach the Windows driver disc" : "Detach the tools image")
        }
      }
      if session.usesWindowsDriverDisc, configuration.supportMedia != nil, session.canStartSelected
      {
        Text(session.windowsDriverDiscGuidance)
          .font(.callout).vmSupportingText()
      }
      HStack(spacing: 12) {
        Button(
          "Networking… · Experimental", systemImage: "network", action: session.showNetworkSettings
        )
        .vmGlassControl().disabled(!session.canEditNetworkSettings)
        .accessibilityLabel("Networking settings, experimental")
        .help("Edit networking while this VM is stopped. Changes apply on its next start.")
        Text("Changes apply on the next start.")
          .font(.callout).vmSupportingText()
      }
      if let notice = session.diskCapacityNotice {
        Label(notice, systemImage: "checkmark.circle").font(.callout).vmSupportingText()
          .fixedSize(horizontal: false, vertical: true)
      }
      if session.isBusy {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Preserving VM files and completing the operation…")
            .font(.callout).vmSupportingText()
        }.accessibilityElement(children: .combine)
      }
    }
  }

  private func machineMetric(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(value).font(.title3.weight(.medium)).monospacedDigit()
      Text(title).font(.caption).vmSupportingText()
    }.accessibilityElement(children: .combine)
  }
}

/// Keep SwiftUI's delegate and native fullscreen behavior on hosts with a dismissal policy.
private struct OwningWindowDismissPolicy: ViewModifier {
  @ObservedObject var session: DesktopSession
  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content.windowDismissBehavior(session.isBusy ? .disabled : .automatic)
    } else {
      content
    }
  }
}

/// Forward public delegate messages except guest fullscreen visibility and the legacy close guard.
/// Retain the original forwarding target until restoration so its advertised selectors stay valid.
final class OwningWindowCloseDelegate: NSObject, NSWindowDelegate {
  @MainActor weak var window: NSWindow?
  @MainActor private weak var session: DesktopSession?
  let forwardedDelegate: (any NSWindowDelegate)?

  @MainActor init(
    window: NSWindow, session: DesktopSession, forwardedDelegate: (any NSWindowDelegate)?
  ) {
    self.window = window
    self.session = session
    self.forwardedDelegate = forwardedDelegate
    super.init()
  }

  @MainActor func windowShouldClose(_ sender: NSWindow) -> Bool {
    if #unavailable(macOS 15), sender === window, session?.isBusy == true {
      session?.keepOwningWindowOpen(sender)
      return false
    }
    let allowed = forwardedDelegate?.windowShouldClose?(sender) ?? true
    if allowed { session?.restoreWindowDelegate(after: self) }
    return allowed
  }

  @MainActor func window(
    _ sender: NSWindow,
    willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
  ) -> NSApplication.PresentationOptions {
    let forwarded =
      forwardedDelegate?.window?(
        sender, willUseFullScreenPresentationOptions: proposedOptions) ?? proposedOptions
    guard sender === window, let session, session.isActive, !session.showingLibrary else {
      return forwarded
    }
    return GuestFullscreenPresentation.guestOptions(forwarded)
  }

  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || forwardedDelegate?.responds(to: selector) == true
  }

  override func forwardingTarget(for selector: Selector!) -> Any? {
    if let forwardedDelegate, forwardedDelegate.responds(to: selector) {
      return forwardedDelegate
    }
    return super.forwardingTarget(for: selector)
  }
}

private struct GuestSurface: NSViewRepresentable {
  let backend: AppleVirtualMachine
  let captured: Bool
  let onApplied: @MainActor (PixelSize) -> Void
  let onAttachment: @MainActor (VZVirtualMachineView) -> Void
  func makeCoordinator() -> DisplayObserver { DisplayObserver(onApplied: onApplied) }
  func makeNSView(context: Context) -> VZVirtualMachineView {
    let view = GuestView()
    view.onAttachment = onAttachment
    view.virtualMachine = backend.machine
    view.automaticallyReconfiguresDisplay = true
    view.capturesSystemKeys = captured
    if let display = backend.machine.graphicsDevices.first?.displays.first {
      context.coordinator.display = display
      display.addObserver(context.coordinator)
    }
    return view
  }
  func updateNSView(_ view: VZVirtualMachineView, context: Context) {
    view.capturesSystemKeys = captured
  }
  static func dismantleNSView(_ view: VZVirtualMachineView, coordinator: DisplayObserver) {
    if let display = coordinator.display { display.removeObserver(coordinator) }
    view.capturesSystemKeys = false
    (view as? GuestView)?.onAttachment = nil
    view.virtualMachine = nil
  }
}

@MainActor private final class GuestView: VZVirtualMachineView {
  var onAttachment: (@MainActor (VZVirtualMachineView) -> Void)?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onAttachment?(self)
  }
}

@MainActor private final class DisplayObserver: NSObject, @preconcurrency VZGraphicsDisplayObserver
{
  var display: VZGraphicsDisplay?
  private let onApplied: @MainActor (PixelSize) -> Void
  init(onApplied: @escaping @MainActor (PixelSize) -> Void) { self.onApplied = onApplied }
  func displayDidEndReconfiguration(_ display: VZGraphicsDisplay) {
    onApplied(
      PixelSize(width: Int(display.sizeInPixels.width), height: Int(display.sizeInPixels.height)))
  }
}
