// SPDX-License-Identifier: Apache-2.0
import BackendAPI
import Foundation
import Testing

@testable import MacOpenVMCLI
@testable import Qemu

struct RegisteredInputRegionTests {
  @Test func targetIgnoresOnlyPixelsOutsideTheReviewedArea() throws {
    let epoch = UUID()
    let region = try RegisteredInputRegion(x: 32, y: 32, width: 64, height: 64)
    var data = Data(repeating: 0, count: 128 * 128 * 4)
    func frame(_ data: Data, size: PixelSize = PixelSize(width: 128, height: 128)) -> RFBFrame {
      RFBFrame(connectionEpoch: epoch, sequence: 1, size: size, rgbaData: data)
    }
    let original = try region.digest(frame(data), epoch: epoch)
    data[0] = 7
    #expect(try region.digest(frame(data), epoch: epoch) == original)
    data[(32 * 128 + 32) * 4] = 1
    #expect(try region.digest(frame(data), epoch: epoch) != original)
    #expect(throws: VMError.self) { try region.digest(frame(data), epoch: UUID()) }
    #expect(throws: VMError.self) { try region.digest(frame(Data()), epoch: epoch) }
    #expect(region.contains(clickX: 32, clickY: 32))
    #expect(!region.contains(clickX: 96, clickY: 32))
    #expect(!region.contains(clickX: 31, clickY: 32))
  }
  @Test func geometryAndAreaBoundsArePartOfTheGuard() throws {
    for (x, y, w, h) in [(0, 0, 63, 64), (-1, 0, 64, 64), (0, 0, 2049, 64), (8191, 0, 64, 64)] {
      #expect(throws: VMError.self) { try RegisteredInputRegion(x: x, y: y, width: w, height: h) }
    }
    let epoch = UUID()
    let region = try RegisteredInputRegion(x: 0, y: 0, width: 64, height: 64)
    let a = RFBFrame(
      connectionEpoch: epoch, sequence: 1, size: PixelSize(width: 64, height: 64),
      rgbaData: Data(repeating: 0, count: 64 * 64 * 4))
    let b = RFBFrame(
      connectionEpoch: epoch, sequence: 1, size: PixelSize(width: 128, height: 64),
      rgbaData: Data(repeating: 0, count: 128 * 64 * 4))
    #expect(try region.digest(a, epoch: epoch) != region.digest(b, epoch: epoch))
  }
}
