# SPDX-License-Identifier: Apache-2.0
"""Post-acknowledgement archive faults on private fake files; no durability claim."""
import unittest

from linux_agent_transaction_fixture import GenerationFixture


class LinuxAgentGenerationArchiveFlushTests(unittest.TestCase):
    def archive_failure(self, offset):
        f = GenerationFixture()
        self.addCleanup(f.close)
        f.install(); f.upgrade()
        protected = f.protected()
        kernel = f.path_identity(f.kernel_lock)
        program = f.path_identity(f.program)
        state = f.path_identity(f.owned_state)
        prior = f.journal.read_bytes()
        calls = f.service_mutations()
        sync_count = f.state()["syncs"] + offset
        f.rollback(extra_env={"MVO_FAIL_AFTER_SYNC": str(sync_count)}, success=False)
        self.assertEqual(f.state()["syncs"], sync_count)
        self.assertEqual((f.journal.parent / "previous-transaction").read_bytes(), prior)
        self.assertEqual(f.journal.read_bytes(), prior)
        self.assertEqual(f.path_identity(f.program), program)
        self.assertEqual(f.path_identity(f.owned_state), state)
        self.assertEqual(f.current_pin(), f.pin_b)
        self.assertTrue(f.state()["running"])
        self.assertEqual(f.service_mutations(), calls)
        self.assertEqual(f.protected(), protected)
        f.assert_generations_present(self)
        f.recover(source=f.pin_b, target=f.pin_a)
        self.assertEqual(f.current_pin(), f.pin_a)
        self.assertEqual((f.program / "macopenvm-agent").read_bytes(), (f.payload_a / "agent").read_bytes())
        self.assertEqual((f.slot(f.program, "failed") / "macopenvm-agent").read_bytes(), (f.payload_b / "agent").read_bytes())
        self.assertEqual((f.journal.parent / "previous-transaction").read_bytes(), prior)
        self.assertEqual(f.protected(), protected)
        self.assertEqual(f.path_identity(f.kernel_lock), kernel)

    def test_archive_file_flush_post_ack_failure_preserves_exact_reverse_recovery(self):
        self.archive_failure(1)

    def test_archive_parent_flush_post_ack_failure_preserves_exact_reverse_recovery(self):
        self.archive_failure(2)


if __name__ == "__main__":
    unittest.main()
