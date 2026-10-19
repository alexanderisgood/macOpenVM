# SPDX-License-Identifier: Apache-2.0
"""Source admission guards only; no VM, worker, native build or free-space mutation."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class WindowsStartupStorageGuards(unittest.TestCase):
    def test_default_probe_samples_vm_directory_without_counting_purgeable_space(self):
        source = (ROOT / 'Storage/WindowsRuntimeStorageAdmission.swift').read_text()
        self.assertIn('VMFiles().availableStorageCapacity(at: directory)', source)
        self.assertIn('minimumAvailableBytes: UInt64 = 4 * 1_073_741_824', source)
        self.assertIn('available >= minimumAvailableBytes', source)
        self.assertIn('this check does not reserve space', source)
        probe = (ROOT / 'Storage/DestinationStorageCapacity.swift').read_text()
        self.assertIn('fstatfs(fd, &filesystem)', probe)
        self.assertIn('blocks: filesystem.f_bavail', probe)

    def test_app_checks_current_capacity_before_run_namespace_or_parent_creation(self):
        source = (ROOT / 'App/DesktopWindowsRuntime.swift').read_text()
        launch = source[source.index('  func launch() async throws {', source.index('@MainActor final class DesktopWindowsRuntime')):]
        self.assertLess(launch.index('priorSession = try await Self.preflight('),
                        launch.index('let records = directory.appendingPathComponent(".runtime"'))
        self.assertLess(launch.index('priorSession = try await Self.preflight('),
                        launch.index('let actual = DesktopWindowsParent('))
        preflight = source[source.index('  static func preflight('):source.index('  static func qualifyTermination(')]
        self.assertIn('WindowsRuntimeStorageAdmission.readCapacity', preflight)
        self.assertLess(preflight.index('let lock = try VMLock('),
                        preflight.index('WindowsRuntimeStorageAdmission.requireCapacity('))
        self.assertLess(preflight.index('intent?.state == .settled'),
                        preflight.index('WindowsRuntimeStorageAdmission.requireCapacity('))
        self.assertIn('in: directory, capacity: storageCapacity', preflight)
        self.assertIn('QemuRegisteredAdmission.validateStoredState(', preflight)

    def test_real_worker_rechecks_capacity_before_minting_permit(self):
        worker = (ROOT / 'CLI/RegisteredWindowsWorker.swift').read_text()
        check = worker.index('WindowsRuntimeStorageAdmission.requireCapacity(in: directory)')
        self.assertLess(worker.index('let lock = try VMLock('), check)
        self.assertLess(worker.index('guard configuration.id == initial.id, lock.owns(directory)'), check)
        for operation in ('RegisteredWorkerPreflight.prepare(', 'RegisteredWorkerCustody(',
                          'server.start()', 'custody.retain()', 'RecordedRuntimeOwner.open('):
            self.assertLess(check, worker.index(operation))
        self.assertIn('RegisteredWindowsRuntimeStore(configuration: configuration, lock: lock)', worker)
        self.assertLess(worker.index('RecordedRuntimeOwner.open('), worker.index('await coordinator.start()'))
        store = (ROOT / 'CLI/RegisteredWindowsRuntimeStore.swift').read_text()
        begin = store[store.index('  func beginOwnership('):store.index('  func commitOwnership(')]
        self.assertLess(begin.index('guard !attempted, self.lock === lock'),
                        begin.index('files.beginRuntimeSession('))
        self.assertIn('RegisteredWindowsPlatformFlush.verifyConfiguration(configuration', begin)


if __name__ == '__main__':
    unittest.main()
