// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import VMCore

@testable import MacOpenVMApp

@Suite struct VMLibraryPresentationTests {
  private let location = URL(fileURLWithPath: "/private/tmp/VM.macopenvm/configuration.json")
  private let identity = UUID()

  @Test func savedEntriesNeverInheritAnotherVMsRuntimeOrRecoveryState() {
    let other = URL(fileURLWithPath: "/private/tmp/Other/VM.macopenvm/configuration.json")
    let selections: [(URL?, UUID?)] = [
      (other, identity), (location, UUID()), (nil, identity), (location, nil), (nil, nil),
    ]
    for (selectedURL, selectedID) in selections {
      for state in VMState.allCases {
        #expect(
          VMLibraryPresentation.rowStatus(
            entryURL: location, entryID: identity, selectedURL: selectedURL,
            selectedID: selectedID, state: state, isActive: true, isBusy: true,
            needsRecovery: true) == .saved)
      }
    }
  }

  @Test func matchingURLAndUUIDAreRequiredBeforeShowingASelectedVM() {
    #expect(status() == .selected)
    #expect(status().title == "Selected VM")
    #expect(status().guidance == nil)
  }

  @Test func recoveryRemainsVisibleEvenWhenNoGuestIsActive() {
    for state in [VMState.stopped, .failed, .running] {
      let result = status(state: state, needsRecovery: true)
      #expect(result == .needsRecovery)
      #expect(result.title == "Needs recovery")
      #expect(result.guidance?.contains("Preserve") == true)
    }
    #expect(status(state: .running, isActive: true, needsRecovery: true) == .needsRecovery)
  }

  @Test func failedAndBusySelectedVMsAreNeverPresentedAsReady() {
    #expect(status(state: .failed) == .needsAttention)
    #expect(status(state: .failed, isBusy: true) == .needsAttention)
    #expect(status(isBusy: true) == .working)
    #expect(status(isBusy: true).guidance?.contains("Wait") == true)
  }

  @Test func activeLifecycleReportsPendingShutdownWithoutClaimingCompletion() {
    #expect(status(state: .running, isActive: true).title == "Running")
    #expect(status(state: .paused, isActive: true).title == "Paused")
    let pending = status(state: .stopping, isActive: true, isBusy: true)
    #expect(pending == .active(.stopping))
    #expect(pending.title == "Shutdown pending")
    #expect(pending.guidance?.contains("return to this VM") == true)
    #expect(status(state: .stopped, isActive: true).title == "Active VM")
  }

  @Test func inactiveStateDoesNotInventALiveGuest() {
    #expect(status(state: .running) == .selected)
    #expect(status(state: .stopping, isBusy: true) == .working)
  }

  @Test func unavailablePreferencesDoNotLookLikeAnEmptySuccessfulLibrary() {
    #expect(
      VMLibraryPresentation.emptyState(
        savedCount: 0, matchingCount: 0, hasLibraryError: true) == .unavailable)
    #expect(
      VMLibraryPresentation.emptyState(
        savedCount: 0, matchingCount: 0, hasLibraryError: false) == .noSavedVMs)
  }

  @Test func filteredEntriesPreserveSearchRecoveryEvenAfterAPreferencesWriteError() {
    #expect(
      VMLibraryPresentation.emptyState(
        savedCount: 3, matchingCount: 0, hasLibraryError: true) == .noMatches)
    #expect(
      VMLibraryPresentation.emptyState(
        savedCount: 3, matchingCount: 1, hasLibraryError: true) == nil)
    #expect(
      VMLibraryPresentation.EmptyState.noMatches.message.contains("clear the search"))
  }

  @Test func searchUsesTheSameWhitespaceBoundaryAsTheLibrary() {
    for query in ["", " ", "\t\n"] { #expect(!VMLibraryPresentation.hasSearch(query)) }
    for query in ["Windows", " Linux ", "\tVM\n"] {
      #expect(VMLibraryPresentation.hasSearch(query))
    }
  }

  private func status(
    state: VMState = .stopped, isActive: Bool = false, isBusy: Bool = false,
    needsRecovery: Bool = false
  ) -> VMLibraryPresentation.RowStatus {
    VMLibraryPresentation.rowStatus(
      entryURL: location, entryID: identity, selectedURL: location, selectedID: identity,
      state: state, isActive: isActive, isBusy: isBusy, needsRecovery: needsRecovery)
  }
}
