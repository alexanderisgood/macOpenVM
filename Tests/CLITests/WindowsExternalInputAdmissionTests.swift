// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Testing

@testable import MacOpenVMCLI

/// Pure navigation/frame gates; no socket, worker, frame or guest action.
@Suite struct WindowsExternalInputAdmissionTests {
  private let fresh = String(repeating: "a", count: 64)
  private let stale = String(repeating: "b", count: 64)

  @Test func onlyExplicitNavigationKeysAndExactActionArgumentsAreAdmitted() throws {
    let pixels = PixelSize(width: 800, height: 600)
    for key in [
      "tab", "return", "space", "escape", "up", "down", "home", "end", "pageup", "pagedown",
    ] {
      let request = try WindowsExternalInputRequest(
        action: "key", expectedFrame: fresh, x: nil, y: nil, key: key)
      #expect(request.admitsFrame(hash: fresh, size: pixels))
      #expect(!request.admitsFrame(hash: stale, size: pixels))
    }
    for key in ["password", "a", "text", "F10", "shift", "Return", "control", "", "\n"] {
      #expect(throws: VMError.self) {
        try WindowsExternalInputRequest(
          action: "key", expectedFrame: fresh, x: nil, y: nil, key: key)
      }
    }
    for action in ["type", "paste", "shutdown", "force-stop", "resume", "start", ""] {
      #expect(throws: VMError.self) {
        try WindowsExternalInputRequest(
          action: action, expectedFrame: fresh, x: nil, y: nil, key: nil)
      }
    }
    #expect(throws: VMError.self) {
      try WindowsExternalInputRequest(
        action: "key", expectedFrame: fresh, x: 1, y: nil, key: "return")
    }
    #expect(throws: VMError.self) {
      try WindowsExternalInputRequest(
        action: "click", expectedFrame: fresh, x: 1, y: 1, key: "return")
    }
  }

  @Test func mutationsNeedFreshHashAndCoordinatesInsideActualFrame() throws {
    let click = try WindowsExternalInputRequest(
      action: "click", expectedFrame: fresh, x: 799, y: 599, key: nil)
    #expect(click.admitsFrame(hash: fresh, size: PixelSize(width: 800, height: 600)))
    #expect(!click.admitsFrame(hash: stale, size: PixelSize(width: 800, height: 600)))
    #expect(!click.admitsFrame(hash: fresh, size: PixelSize(width: 799, height: 600)))
    #expect(!click.admitsFrame(hash: fresh, size: PixelSize(width: 800, height: 599)))
    #expect(!click.admitsFrame(hash: fresh, size: PixelSize(width: 8192, height: 8192)))
    for hash in [nil, "", "abc", String(repeating: "A", count: 64)] {
      #expect(throws: VMError.self) {
        try WindowsExternalInputRequest(action: "click", expectedFrame: hash, x: 1, y: 1, key: nil)
      }
      #expect(throws: VMError.self) {
        try WindowsExternalInputRequest(
          action: "key", expectedFrame: hash, x: nil, y: nil, key: "tab")
      }
    }
    for point in [(-1, 0), (0, -1), (8192, 0), (0, 8192), (Int.max, 1)] {
      #expect(throws: VMError.self) {
        try WindowsExternalInputRequest(
          action: "click", expectedFrame: fresh, x: point.0, y: point.1, key: nil)
      }
    }
  }

  @Test func snapshotRequiresNoMutationArgumentsAndReturnsOnlyBoundedFrameAdmission() throws {
    let snapshot = try WindowsExternalInputRequest(
      action: "snapshot", expectedFrame: nil, x: nil, y: nil, key: nil)
    #expect(snapshot.admitsFrame(hash: fresh, size: PixelSize(width: 800, height: 600)))
    #expect(!snapshot.admitsFrame(hash: "invalid", size: PixelSize(width: 800, height: 600)))
    #expect(!snapshot.admitsFrame(hash: fresh, size: PixelSize(width: 0, height: 600)))
    #expect(throws: VMError.self) {
      try WindowsExternalInputRequest(
        action: "snapshot", expectedFrame: fresh, x: nil, y: nil, key: nil)
    }
    #expect(throws: VMError.self) {
      try WindowsExternalInputRequest(action: "snapshot", expectedFrame: nil, x: 1, y: 1, key: nil)
    }
    #expect(throws: VMError.self) {
      try WindowsExternalInputRequest(
        action: "snapshot", expectedFrame: nil, x: nil, y: nil, key: "tab")
    }
  }
}
