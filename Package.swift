// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let strict: [SwiftSetting] = [
  .unsafeFlags(["-warnings-as-errors", "-strict-concurrency=complete"])
]
let package = Package(
  name: "macOpenVM",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "macopenvm", targets: ["MacOpenVMCLI"]),
    .executable(name: "macOpenVMDesktop", targets: ["MacOpenVMApp"]),
    .executable(name: "RfbDecodeBenchmark", targets: ["RfbDecodeBenchmark"]),
    .executable(name: "RfbReceiveBenchmark", targets: ["RfbReceiveBenchmark"]),
  ],
  targets: [
    .target(
      name: "SharedFrameWire", path: "Backends/SharedFrameWire",
      linkerSettings: [.linkedLibrary("proc")]),
    .target(name: "BackendAPI", path: "Backends/BackendAPI", swiftSettings: strict),
    .target(
      name: "RuntimeIPC", dependencies: ["BackendAPI"], path: "RuntimeIPC", swiftSettings: strict),
    .target(name: "AgentProtocol", path: "GuestAgent/Host", swiftSettings: strict),
    .target(
      name: "VMCore", dependencies: ["BackendAPI", "VMStorage", "RuntimeIPC"], path: "Core",
      swiftSettings: strict
    ),
    .target(
      name: "VMStorage", dependencies: ["BackendAPI"], path: "Storage", swiftSettings: strict),
    .target(
      name: "AppleVz", dependencies: ["BackendAPI"], path: "Backends/AppleVz", swiftSettings: strict
    ),
    .target(
      name: "Qemu", dependencies: ["BackendAPI", "VMStorage", "SharedFrameWire"],
      path: "Backends/Qemu",
      exclude: ["patches"],
      swiftSettings: strict),
    .executableTarget(
      name: "MacOpenVMCLI",
      dependencies: ["VMCore", "VMStorage", "AppleVz", "Qemu", "RuntimeIPC", "AgentProtocol"],
      path: "CLI",
      swiftSettings: strict),
    .executableTarget(
      name: "MacOpenVMApp", dependencies: ["VMCore", "VMStorage", "AppleVz", "Qemu", "RuntimeIPC"],
      path: "App",
      swiftSettings: strict),
    .executableTarget(
      name: "ProcessMonitorBenchmark", dependencies: ["Qemu"], path: "Benchmarks/ProcessMonitor",
      swiftSettings: strict),
    .executableTarget(
      name: "RfbDecodeBenchmark", dependencies: ["Qemu"], path: "Benchmarks/RfbDecode",
      swiftSettings: strict),
    .executableTarget(
      name: "RfbReceiveBenchmark", dependencies: ["Qemu"], path: "Benchmarks/RfbReceive",
      swiftSettings: strict),
    .target(name: "SharedFrameFixture", path: "Tests/SharedFrameFixture"),
    .testTarget(
      name: "CLITests", dependencies: ["MacOpenVMCLI", "VMCore", "VMStorage"],
      path: "Tests/CLITests",
      swiftSettings: strict),
    .testTarget(
      name: "AppTests", dependencies: ["MacOpenVMApp"], path: "Tests/AppTests",
      swiftSettings: strict),
    .testTarget(
      name: "CoreTests", dependencies: ["VMCore", "VMStorage", "RuntimeIPC"],
      path: "Tests/CoreTests",
      swiftSettings: strict),
    .testTarget(
      name: "StorageTests", dependencies: ["VMStorage"], path: "Tests/StorageTests",
      swiftSettings: strict),
    .testTarget(
      name: "BackendTests",
      dependencies: [
        "AppleVz", "Qemu", "VMCore", "SharedFrameWire", "SharedFrameFixture", "MacOpenVMApp",
      ], path: "Tests/BackendTests",
      swiftSettings: strict),
    .testTarget(
      name: "RuntimeIPCTests", dependencies: ["RuntimeIPC", "BackendAPI"],
      path: "Tests/RuntimeIPCTests",
      swiftSettings: strict),
    .testTarget(
      name: "AgentProtocolTests", dependencies: ["AgentProtocol"], path: "Tests/AgentProtocolTests",
      resources: [.copy("vectors.json")],
      swiftSettings: strict),
  ],
  swiftLanguageModes: [.v6]
)
