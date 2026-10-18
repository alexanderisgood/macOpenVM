// SPDX-License-Identifier: Apache-2.0
import AppleVz
import BackendAPI
import Foundation
import Qemu
import Testing

@Test func windowsFailsClosed() {
  #expect(throws: VMError.self) { try QemuPlan.windowsReadiness() }
}
@Test func qemuEscapesOptionPathsWithoutShell() {
  #expect(QemuPlan.escape("/a,b/$name`command`") == "/a,,b/$name`command`")
}
@Test func qemuPlanHasHVFWithoutFallbackAndNoNetwork() throws {
  let c = VMConfiguration(name: "Linux", guest: .linux, backend: .qemuHVF)
  let plan = try QemuPlan.linux(
    configuration: c, directory: URL(fileURLWithPath: "/vm"),
    executable: URL(fileURLWithPath: "/qemu"), firmwareCode: URL(fileURLWithPath: "/code,fd"),
    firmwareVariables: URL(fileURLWithPath: "/vars"),
    host: HostResources(cpuCount: 8, memoryBytes: 16 * 1_073_741_824))
  #expect(plan.arguments.contains("hvf"))
  #expect(!plan.arguments.contains(where: { $0.contains("tcg") }))
  #expect(plan.arguments.contains("none"))
  #expect(plan.arguments.contains(where: { $0.contains("/code,,fd") }))
}

@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["MACOPENVM_ENTITLEMENT_TEST"] == "1",
    "Requires a separately signed test executable; real guest acceptance is procedure B1, not this probe."
  ))
@MainActor func signedRunnerEntitlement() {
  #expect(HostProbe.hasVirtualizationEntitlement())
}
