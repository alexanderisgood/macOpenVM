// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Qemu
import Testing

@testable import MacOpenVMApp

@Suite struct WindowsGraphicsSettingsTests {
  @Test func ordinaryDefaultsKeepBasicDisplayAndSixtyHertz() throws {
    let settings = WindowsGraphicsSettings()
    #expect(settings.mode == .basic && settings.refreshRate == .hz60)
    #expect(settings.initialWidth == 1920 && settings.initialHeight == 1080)
    #expect(try settings.reviewedInitialDisplay(hostMaximumFramesPerSecond: nil) == nil)
    #expect(try settings.reviewedAcceleratedDisplay(hostMaximumFramesPerSecond: 120) == nil)
  }

  @Test func anExplicitAcceleratedChoiceConstructsOnlyTheExistingBoundedRecipe() throws {
    let settings = WindowsGraphicsSettings(mode: .accelerated)
    let initial = try #require(
      try settings.reviewedInitialDisplay(hostMaximumFramesPerSecond: nil))
    #expect(initial.initialPixels == PixelSize(width: 1920, height: 1080))
    let recipe = try #require(
      try settings.reviewedAcceleratedDisplay(hostMaximumFramesPerSecond: nil))
    #expect(recipe.initialPixels == initial.initialPixels)
    #expect(recipe.separateFirmware && recipe.hostWindow == .fourGiB)
    #expect(recipe.refreshRate == .hz60 && settings.refreshRate.reviewed == .hz60)
  }

  @Test func basicDisplayIgnoresInvalidAcceleratedFieldsAndReturnsConservativeDefaults() throws {
    let settings = WindowsGraphicsSettings(
      mode: .basic, initialWidth: -1, initialHeight: Int.max, refreshRate: .hz120)
    #expect(try settings.validated(canUse120: false) == WindowsGraphicsSettings())
    #expect(try settings.reviewedInitialDisplay(hostMaximumFramesPerSecond: 0) == nil)
    #expect(try settings.reviewedAcceleratedDisplay(hostMaximumFramesPerSecond: nil) == nil)
    var draft = WindowsGraphicsSettingsDraft(settings: settings)
    draft.widthText = "1920.5"
    draft.heightText = "not a number"
    #expect(try draft.prepared(canUse120: false) == WindowsGraphicsSettings())
  }

  @Test func geometryUsesTheReviewedDimensionAndPixelBudgetBoundaries() throws {
    for (width, height) in [(320, 200), (8192, 2048), (4096, 4096), (1920, 1080)] {
      let settings = WindowsGraphicsSettings(
        mode: .accelerated, initialWidth: width, initialHeight: height)
      #expect(
        try settings.reviewedInitialDisplay(hostMaximumFramesPerSecond: 60)?.initialPixels
          == PixelSize(width: width, height: height))
    }
    for (width, height) in [
      (-1, 1080), (0, 1080), (319, 1080), (8193, 200), (1920, 199), (320, 8193),
      (8192, 8192), (4097, 4096), (Int.max, Int.max),
    ] {
      let settings = WindowsGraphicsSettings(
        mode: .accelerated, initialWidth: width, initialHeight: height)
      #expect(throws: VMError.self) {
        try settings.reviewedInitialDisplay(hostMaximumFramesPerSecond: 120)
      }
      #expect(throws: VMError.self) {
        try settings.reviewedAcceleratedDisplay(hostMaximumFramesPerSecond: 120)
      }
    }
  }

  @Test func highRefreshIsExplicitAndRejectsMissingOrInsufficientHostCapability() throws {
    let settings = WindowsGraphicsSettings(mode: .accelerated, refreshRate: .hz120)
    #expect(try settings.validatedPreference() == settings)
    for maximum in [Int?.none, 0, 60, 119] {
      #expect(throws: VMError.self) {
        try settings.reviewedInitialDisplay(hostMaximumFramesPerSecond: maximum)
      }
      #expect(throws: VMError.self) {
        try settings.reviewedAcceleratedDisplay(hostMaximumFramesPerSecond: maximum)
      }
    }
    for maximum in [120, 144] {
      let recipe = try #require(
        try settings.reviewedAcceleratedDisplay(hostMaximumFramesPerSecond: maximum))
      #expect(recipe.refreshRate == .hz120 && settings.refreshRate.reviewed == .hz120)
    }
    #expect(throws: VMError.self) { try settings.validated(canUse120: false) }
  }

  @Test func declarativeValidationDoesNotInferAHostAndStillRejectsInvalidGeometry() throws {
    let settings = WindowsGraphicsSettings(mode: .accelerated, refreshRate: .hz120)
    #expect(try settings.validatedPreference() == settings)
    #expect(throws: VMError.self) { try settings.validated(canUse120: false) }
    #expect(
      try WindowsGraphicsSettings(mode: .basic, initialWidth: -1, refreshRate: .hz120)
        .validatedPreference() == WindowsGraphicsSettings())
    #expect(throws: VMError.self) {
      try WindowsGraphicsSettings(mode: .accelerated, initialWidth: 8192, initialHeight: 8192)
        .validatedPreference()
    }
  }

  @Test func textDraftRejectsFractionsMalformedValuesAndOverflowInsteadOfCoercingThem() throws {
    let invalid = [
      "", " ", "1920.5", "1920.0", "1.92e3", "1,920", "-1920", "+1920", "∞", "１９２０",
      String(repeating: "9", count: 100),
    ]
    for text in invalid {
      var draft = WindowsGraphicsSettingsDraft(settings: .init(mode: .accelerated))
      draft.widthText = text
      #expect(throws: VMError.self) { try draft.prepared(canUse120: true) }
      #expect(draft.widthText == text && draft.settings.initialWidth == 1920)
      draft.widthText = "1920"
      draft.heightText = text
      #expect(throws: VMError.self) { try draft.prepared(canUse120: true) }
      #expect(draft.heightText == text && draft.settings.initialHeight == 1080)
    }
  }

  @Test func textDraftChecksBoundsAndCurrentRefreshCapabilityBeforeCommit() throws {
    var draft = WindowsGraphicsSettingsDraft(settings: .init(mode: .accelerated))
    draft.widthText = " 1920\n"
    draft.heightText = "1080 "
    #expect(try draft.prepared(canUse120: false).initialWidth == 1920)
    #expect(try draft.prepared(canUse120: false).initialHeight == 1080)
    draft.settings.refreshRate = .hz120
    #expect(throws: VMError.self) { try draft.prepared(canUse120: false) }
    #expect(try draft.prepared(canUse120: true).refreshRate == .hz120)
    draft.widthText = "8192"
    draft.heightText = "8192"
    #expect(throws: VMError.self) { try draft.prepared(canUse120: true) }
    draft.widthText = "-1"
    draft.heightText = "1080"
    #expect(throws: VMError.self) { try draft.prepared(canUse120: true) }
  }
}
