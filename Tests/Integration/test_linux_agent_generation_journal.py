# SPDX-License-Identifier: Apache-2.0
"""Journal/flush prefix tests on a private fakeroot; not power-loss durability evidence."""
import os
import shutil
import unittest

from linux_agent_transaction_fixture import GenerationFixture


class LinuxAgentGenerationJournalTests(unittest.TestCase):
    def fixture(self):
        fixture = GenerationFixture()
        self.addCleanup(fixture.close)
        return fixture

    def transaction_trace(self, operation="upgrade"):
        f = self.fixture()
        f.install()
        if operation == "rollback": f.upgrade()
        start = len(f.state()["calls"])
        getattr(f, operation)()
        return [call for call in f.state()["calls"][start:] if call[0] in ("mv", "sync")]

    # Per-process cache contains only immutable numeric offset tuples. It is
    # populated by actual test execution, never by import/discovery/--list.
    _boundary_offsets_by_operation = {}

    def _journal_boundary_offsets(self, operation, family):
        cache = type(self)._boundary_offsets_by_operation
        if operation not in cache:
            trace = self.transaction_trace(operation)
            moves = [call for call in trace if call[0] == "mv"]
            publication = tuple(index for index, call in enumerate(moves, 1)
                                if call[1].endswith("/transaction.next"))
            syncs = [call for call in trace if call[0] == "sync"]
            # Rollback first flushes its prior upgrade archive and archive parent.
            skip = 2 if operation == "rollback" else 0
            journal_flush = tuple(index for index, call in enumerate(syncs, 1)
                                  if index > skip and
                                  (call[1].endswith("/transaction.next") or
                                   call[1].endswith("/macopenvm-agent.install-lock")))
            sync_index = 0; pending = 0; namespace_flush = []
            for call in trace:
                if call[0] == "mv" and not call[1].endswith("/transaction.next"):
                    pending = 2
                elif call[0] == "sync":
                    sync_index += 1
                    if pending:
                        namespace_flush.append(sync_index); pending -= 1
            # Preserve the original complete trace inventories before selecting
            # one deterministic ordinal. No hardcoded syscall offset is guessed.
            self.assertEqual(len(publication), 8)
            self.assertEqual(len(journal_flush), 16)
            self.assertEqual(len(namespace_flush), 8)
            cache[operation] = (publication, journal_flush, tuple(namespace_flush))
        return cache[operation][family]

    def _check_journal_publication_boundary(self, operation, boundary_index, after):
        offset = self._journal_boundary_offsets(operation, 0)[boundary_index]
        with self.subTest(operation=operation, offset=offset, after=after):
            f = self.fixture(); f.install()
            if operation == "rollback": f.upgrade()
            protected = f.protected()
            variable = "MVO_FAIL_AFTER_MOVE" if after else "MVO_FAIL_MOVE"
            getattr(f, operation)(extra_env={variable: str(f.state()["moves"] + offset)}, success=False)
            f.assert_generations_present(self)
            self.assertEqual(f.protected(), protected)
            source, target = (f.pin_a, f.pin_b) if operation == "upgrade" else (f.pin_b, f.pin_a)
            f.recover(source=source, target=target)
            self.assertEqual(f.current_pin(), target)
            self.assertEqual(f.protected(), protected)
            self.assertTrue(f.state()["running"])

    def test_before_after_each_rollback_namespace_rename_preserves_prior_upgrade_and_reverse_resume(self):
        baseline = self.fixture(); baseline.install(); baseline.upgrade()
        first = len(baseline.state()["calls"])
        baseline.rollback()
        moves = [call for call in baseline.state()["calls"][first:] if call[0] == "mv"]
        paths = {str(baseline.program), str(baseline.owned_state),
                 str(baseline.slot(baseline.program, "previous")), str(baseline.slot(baseline.owned_state, "previous"))}
        offsets = [index for index, call in enumerate(moves, 1) if call[1] in paths]
        self.assertEqual(len(offsets), 4)
        for offset in offsets:
            for after in (False, True):
                with self.subTest(offset=offset, after=after):
                    f = self.fixture(); f.install(); f.upgrade(); protected = f.protected()
                    upgrade_record = f.journal.read_bytes()
                    variable = "MVO_FAIL_AFTER_MOVE" if after else "MVO_FAIL_MOVE"
                    f.rollback(extra_env={variable: str(f.state()["moves"] + offset)}, success=False)
                    f.assert_generations_present(self)
                    self.assertEqual((f.journal.parent / "previous-transaction").read_bytes(), upgrade_record)
                    self.assertEqual(f.protected(), protected)
                    f.recover(source=f.pin_b, target=f.pin_a)
                    self.assertEqual(f.current_pin(), f.pin_a)
                    self.assertEqual(f.protected(), protected)
                    self.assertEqual((f.journal.parent / "previous-transaction").read_bytes(), upgrade_record)

    def _check_journal_file_parent_flush_boundary(self, operation, boundary_index, after):
        offset = self._journal_boundary_offsets(operation, 1)[boundary_index]
        variable = "MVO_FAIL_AFTER_SYNC" if after else "MVO_FAIL_SYNC"
        with self.subTest(operation=operation, sync=offset, boundary=variable):
            f = self.fixture(); f.install()
            if operation == "rollback": f.upgrade()
            protected = f.protected()
            getattr(f, operation)(extra_env={variable: str(f.state().get("syncs", 0) + offset)}, success=False)
            f.assert_generations_present(self)
            self.assertEqual(f.protected(), protected)
            source, target = (f.pin_a, f.pin_b) if operation == "upgrade" else (f.pin_b, f.pin_a)
            f.recover(source=source, target=target)
            self.assertEqual(f.current_pin(), target)
            self.assertEqual(f.protected(), protected)

    def _check_namespace_parent_flush_boundary(self, operation, boundary_index, after):
        offset = self._journal_boundary_offsets(operation, 2)[boundary_index]
        variable = "MVO_FAIL_AFTER_SYNC" if after else "MVO_FAIL_SYNC"
        with self.subTest(operation=operation, sync=offset, boundary=variable):
            f = self.fixture(); f.install()
            if operation == "rollback": f.upgrade()
            protected = f.protected()
            getattr(f, operation)(extra_env={variable: str(f.state().get("syncs", 0) + offset)}, success=False)
            f.assert_generations_present(self)
            self.assertEqual(f.protected(), protected)
            source, target = (f.pin_a, f.pin_b) if operation == "upgrade" else (f.pin_b, f.pin_a)
            f.recover(source=source, target=target)
            self.assertEqual(f.current_pin(), target)
            self.assertEqual(f.protected(), protected)

    def test_unjournaled_staging_flush_failure_preserves_both_trees_and_refuses_recovery(self):
        trace = self.transaction_trace()
        sync_offsets = []; count = 0
        for call in trace:
            if call[0] == "mv": break
            if call[0] == "sync":
                count += 1
                if not call[1].endswith("/transaction.next"): sync_offsets.append(count)
        self.assertEqual(len(sync_offsets), 10)
        for offset in sync_offsets:
            for variable in ("MVO_FAIL_SYNC", "MVO_FAIL_AFTER_SYNC"):
                with self.subTest(sync=offset, boundary=variable):
                    f = self.fixture(); f.install(); protected = f.protected()
                    f.upgrade(extra_env={variable: str(f.state().get("syncs", 0) + offset)}, success=False)
                    self.assertFalse(f.journal.parent.exists())
                    self.assertTrue(f.state()["running"])
                    self.assertEqual(f.current_pin(), f.pin_a)
                    f.assert_generations_present(self)
                    self.assertEqual(f.protected(), protected)
                    before = f.full_tree(); calls = f.service_mutations()
                    f.recover(success=False)
                    self.assertEqual(f.full_tree(), before)
                    self.assertEqual(f.service_mutations(), calls)

    def test_partial_conflicting_and_phase_gap_next_journals_refuse_unchanged(self):
        for kind in ("partial", "wrong-vm", "gap", "extra"):
            with self.subTest(kind=kind):
                f = self.fixture(); f.install()
                # Prepared journal has published; stop-phase publication leaves valid next.
                f.upgrade(extra_env={"MVO_FAIL_MOVE": str(f.state()["moves"] + 2)}, success=False)
                next_record = f.journal.parent / "transaction.next"
                data = next_record.read_bytes()
                if kind == "partial": changed = data[:-7]
                elif kind == "wrong-vm": changed = data.replace(f.vm_id.lower().encode(), b"11234567-89ab-cdef-0123-456789abcdef")
                elif kind == "gap": changed = data.replace(b"phase=stop", b"phase=publish-state")
                else: changed = data + b"extra=unrelated\n"
                next_record.write_bytes(changed)
                before = f.full_tree(); calls = f.service_mutations()
                f.recover(success=False)
                self.assertEqual(f.full_tree(), before)
                self.assertEqual(f.service_mutations(), calls)

    def test_noncanonical_current_journal_and_indirect_generation_evidence_refuse_unchanged(self):
        for kind in ("duplicate", "reordered", "unknown-phase", "wrong-vm", "extra-entry",
                     "journal-symlink", "journal-hardlink", "program-symlink", "state-hardlink"):
            with self.subTest(kind=kind):
                f = self.fixture(); f.install()
                # A has stopped; the first namespace rename has not occurred.
                f.upgrade(extra_env={"MVO_FAIL_MOVE": str(f.state()["moves"] + 4)}, success=False)
                record = f.journal.read_bytes()
                external = None
                if kind == "duplicate": f.journal.write_bytes(record + b"phase=save-program\n")
                elif kind == "reordered":
                    lines = record.splitlines(keepends=True); lines[3], lines[4] = lines[4], lines[3]
                    f.journal.write_bytes(b"".join(lines))
                elif kind == "unknown-phase": f.journal.write_bytes(record.replace(b"phase=save-program", b"phase=unknown"))
                elif kind == "wrong-vm":
                    f.journal.write_bytes(record.replace(f.vm_id.lower().encode(), b"11234567-89ab-cdef-0123-456789abcdef"))
                elif kind == "extra-entry": (f.journal.parent / "unrelated").write_bytes(b"preserve this unknown evidence\n")
                elif kind in ("journal-symlink", "journal-hardlink"):
                    target = f.base / "saved-journal"; target.write_bytes(record); target.chmod(0o600)
                    external = target
                    f.journal.unlink()
                    if kind.endswith("symlink"): f.journal.symlink_to(target)
                    else: os.link(target, f.journal)
                elif kind == "program-symlink":
                    target = f.slot(f.program, "next") / "macopenvm-agent"
                    saved = f.base / "saved-agent"; saved.write_bytes(target.read_bytes()); saved.chmod(0o755)
                    external = saved
                    target.unlink(); target.symlink_to(saved)
                else:
                    target = f.slot(f.owned_state, "next") / "generation"
                    saved = f.base / "saved-generation"; saved.write_bytes(target.read_bytes()); saved.chmod(0o600)
                    external = saved
                    target.unlink(); os.link(saved, target)
                before = f.full_tree(); calls = f.service_mutations()
                external_before = f.path_identity(external) if external else None
                f.recover(success=False)
                self.assertEqual(f.full_tree(), before)
                self.assertEqual(f.service_mutations(), calls)
                if external: self.assertEqual(f.path_identity(external), external_before)

    def test_completed_start_with_failed_commit_preserves_running_target_and_both_generations(self):
        f = self.fixture(); f.install(); protected = f.protected()
        # The final phase publication follows four namespace renames and start.
        f.upgrade(extra_env={"MVO_FAIL_MOVE": str(f.state()["moves"] + 12)}, success=False)
        self.assertTrue(f.state()["running"])
        self.assertEqual(f.current_pin(), f.pin_b)
        self.assertEqual(f.journal.read_text().splitlines()[-1], "phase=start")
        self.assertEqual((f.journal.parent / "transaction.next").read_text().splitlines()[-1], "phase=complete")
        f.assert_generations_present(self)
        self.assertEqual(f.protected(), protected)
        f.recover()
        self.assertEqual(f.journal.read_text().splitlines()[-1], "phase=complete")
        self.assertTrue(f.state()["running"])
        self.assertEqual(f.protected(), protected)

    def test_wrong_pins_on_archive_only_rollback_refuse_before_phase_write(self):
        f = self.fixture(); f.install(); f.upgrade()
        f.rollback(extra_env={"MVO_FAIL_AFTER_COPY": str(f.state().get("copies", 0) + 1)}, success=False)
        self.assertTrue((f.journal.parent / "previous-transaction").is_file())
        before = f.full_tree(); calls = f.service_mutations()
        for source, target in (("0" * 64, f.pin_a), (f.pin_b, "0" * 64)):
            result = f.recover(source=source, target=target, success=False)
            self.assertIn(b"pins", result.stderr)
            self.assertEqual(f.full_tree(), before)
            self.assertEqual(f.service_mutations(), calls)
        f.recover(source=f.pin_b, target=f.pin_a)
        self.assertEqual(f.current_pin(), f.pin_a)

    def test_before_after_rollback_archive_copy_and_flush_are_classified_explicitly(self):
        for kind in ("before-copy", "after-copy", "file-sync", "parent-sync"):
            with self.subTest(kind=kind):
                f = self.fixture(); f.install(); f.upgrade(); protected = f.protected()
                if kind.endswith("copy"):
                    variable = "MVO_FAIL_COPY" if kind == "before-copy" else "MVO_FAIL_AFTER_COPY"
                    env = {variable: str(f.state().get("copies", 0) + 1)}
                else:
                    env = {"MVO_FAIL_SYNC": str(f.state().get("syncs", 0) + (1 if kind == "file-sync" else 2))}
                f.rollback(extra_env=env, success=False)
                self.assertEqual(f.current_pin(), f.pin_b)
                self.assertEqual(f.protected(), protected)
                f.assert_generations_present(self)
                if kind == "before-copy": f.rollback()
                else: f.recover(source=f.pin_b, target=f.pin_a)
                self.assertEqual(f.current_pin(), f.pin_a)
                self.assertEqual(f.protected(), protected)

    def test_two_successive_journal_interruptions_and_rollback_next_do_not_overwrite_prior_evidence(self):
        f = self.fixture(); f.install(); protected = f.protected()
        f.upgrade(extra_env={"MVO_FAIL_MOVE": str(f.state()["moves"] + 1)}, success=False)
        # First recovery publishes prepared then interrupts its save-program journal.
        f.recover(extra_env={"MVO_FAIL_MOVE": str(f.state()["moves"] + 2)}, success=False)
        archives = {path.name: path.read_bytes() for path in f.journal.parent.glob("recovery-*")}
        self.assertTrue(archives)
        f.recover()
        for name, data in archives.items(): self.assertEqual((f.journal.parent / name).read_bytes(), data)
        f.rollback(extra_env={"MVO_FAIL_MOVE": str(f.state()["moves"] + 1)}, success=False)
        f.recover(source=f.pin_b, target=f.pin_a)
        self.assertEqual(f.current_pin(), f.pin_a)
        self.assertEqual(f.protected(), protected)
        for name, data in archives.items(): self.assertEqual((f.journal.parent / name).read_bytes(), data)

    def test_ambiguous_missing_or_double_present_namespace_is_not_repaired(self):
        for name in ("program", "state"):
            for kind in ("missing", "both"):
                with self.subTest(name=name, kind=kind):
                    f = self.fixture(); f.install()
                    # Fail after the actual source rename, with its write-ahead phase.
                    offset = 4 if name == "program" else 6
                    f.upgrade(extra_env={"MVO_FAIL_AFTER_MOVE": str(f.state()["moves"] + offset)}, success=False)
                    current = f.program if name == "program" else f.owned_state
                    saved = f.slot(current, "previous")
                    self.assertTrue(saved.is_dir())
                    if kind == "missing": shutil.rmtree(saved)
                    else: shutil.copytree(saved, current)
                    before = f.full_tree(); calls = f.service_mutations()
                    result = f.recover(success=False)
                    self.assertIn(b"namespace", result.stderr)
                    self.assertEqual(f.full_tree(), before)
                    self.assertEqual(f.service_mutations(), calls)



def _journal_boundary_case(helper_name, operation, boundary_index, after, name):
    # Factory arguments freeze every loop parameter in this method's own scope.
    # Calling the factory performs no fixture, trace or subprocess operations.
    def test(self):
        getattr(self, helper_name)(operation, boundary_index, after)
    test.__name__ = name
    test.__qualname__ = "LinuxAgentGenerationJournalTests." + name
    return test


def _register_journal_boundary_tests():
    specifications = (
        ("test_before_after_every_journal_publication_retains_resumable_exact_prefix",
         "_check_journal_publication_boundary", 8),
        ("test_each_journal_file_and_parent_flush_preserves_valid_resume_or_unjournaled_refusal",
         "_check_journal_file_parent_flush_boundary", 16),
        ("test_each_namespace_parent_flush_failure_preserves_the_journaled_postrename_prefix",
         "_check_namespace_parent_flush_boundary", 8),
    )
    for prefix, helper_name, count in specifications:
        for operation in ("upgrade", "rollback"):
            for boundary_index in range(count):
                for after in (False, True):
                    boundary = "after" if after else "before"
                    name = f"{prefix}_{operation}_{boundary_index + 1:02d}_{boundary}"
                    if hasattr(LinuxAgentGenerationJournalTests, name):
                        raise RuntimeError("Duplicate generated journal test: " + name)
                    setattr(LinuxAgentGenerationJournalTests, name,
                            _journal_boundary_case(helper_name, operation, boundary_index, after, name))


_register_journal_boundary_tests()

if __name__ == "__main__":
    unittest.main()
