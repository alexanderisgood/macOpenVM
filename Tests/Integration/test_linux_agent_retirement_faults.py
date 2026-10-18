# SPDX-License-Identifier: Apache-2.0
"""Retirement fault-prefix filesystem fixtures; no native or power-loss claim."""
from pathlib import Path
import os
import shutil
import unittest

from test_linux_agent_retirement import RetirementCase, OTHER_RETIREMENT_ID, OTHER_VM_ID


class LinuxAgentRetirementFaultTests(RetirementCase):
    def field(self, data, name, value):
        prefix = (name + "=").encode()
        lines = data.splitlines(keepends=True)
        self.assertEqual(sum(line.startswith(prefix) for line in lines), 1)
        return b"".join(prefix + value.encode() + b"\n" if line.startswith(prefix) else line for line in lines)

    def assert_resume_refuses_without_mutation(self, fixture, **kwargs):
        before = fixture.full_tree(); calls = fixture.service_mutations()
        fixture.retire(resume=True, success=False, **kwargs)
        self.assertEqual(fixture.full_tree(), before)
        self.assertEqual(fixture.service_mutations(), calls)

    def prepared_record_interruption(self):
        fixture = self.fixture()
        target = fixture.state()["moves"] + 2
        fixture.retire(extra_env={"MVO_FAIL_MOVE": str(target)}, success=False)
        self.assertEqual(fixture.state()["moves"], target)
        self.assertTrue((fixture.retirement / "record.next").is_file())
        return fixture

    def test_before_after_every_namespace_rename_preserves_inodes_and_resumes_twice(self):
        baseline, trace = self.retirement_trace()
        sources = {str(baseline.retirement_next), str(baseline.retirement),
                   str(baseline.slot(baseline.program, "failed")),
                   str(baseline.slot(baseline.owned_state, "failed")), str(baseline.journal.parent)}
        moves = [call for call in trace if call[0] == "mv"]
        offsets = [index for index, call in enumerate(moves, 1) if call[1] in sources]
        self.assertEqual(len(offsets), 5)
        for offset in offsets:
            for after in (False, True):
                with self.subTest(offset=offset, after=after):
                    fixture = self.fixture()
                    current = self.current_identity(fixture); evidence = self.evidence(fixture)
                    target = fixture.state()["moves"] + offset
                    variable = "MVO_FAIL_AFTER_MOVE" if after else "MVO_FAIL_MOVE"
                    fixture.retire(extra_env={variable: str(target)}, success=False)
                    self.assertEqual(fixture.state()["moves"], target)
                    self.finish_interrupted(fixture, evidence, current)

    def test_before_after_every_record_and_confirmation_publication_preserves_exact_prefix(self):
        _, trace = self.retirement_trace()
        moves = [call for call in trace if call[0] == "mv"]
        offsets = [index for index, call in enumerate(moves, 1)
                   if Path(call[1]).name in ("record.next", "confirmation.next")]
        self.assertGreaterEqual(len(offsets), 7)
        for offset in offsets:
            for after in (False, True):
                with self.subTest(offset=offset, after=after):
                    fixture = self.fixture()
                    current = self.current_identity(fixture); evidence = self.evidence(fixture)
                    target = fixture.state()["moves"] + offset
                    variable = "MVO_FAIL_AFTER_MOVE" if after else "MVO_FAIL_MOVE"
                    fixture.retire(extra_env={variable: str(target)}, success=False)
                    self.assertEqual(fixture.state()["moves"], target)
                    self.finish_interrupted(fixture, evidence, current)

    def test_every_observed_file_directory_and_parent_flush_failure_is_recoverable(self):
        _, trace = self.retirement_trace()
        syncs = [call for call in trace if call[0] == "sync"]
        self.assertGreater(len(syncs), 20)
        for offset, call in enumerate(syncs, 1):
            for after in (False, True):
                with self.subTest(offset=offset, path=call[1], after=after):
                    fixture = self.fixture()
                    current = self.current_identity(fixture); evidence = self.evidence(fixture)
                    target = fixture.state().get("syncs", 0) + offset
                    variable = "MVO_FAIL_AFTER_SYNC" if after else "MVO_FAIL_SYNC"
                    fixture.retire(extra_env={variable: str(target)}, success=False)
                    self.assertEqual(fixture.state()["syncs"], target)
                    # The shim models acknowledgement faults, not a power cut.
                    # A cleanup-sync fault can leave an already positively flushed
                    # confirmed receipt. Explicit resume must remain idempotent.
                    self.finish_interrupted(fixture, evidence, current)

    def test_final_archive_move_without_confirmation_blocks_other_mutators(self):
        baseline, trace = self.retirement_trace()
        sync_index = 0; pending = 0; offsets = []
        for call in trace:
            if call[0] == "mv" and call[1] == str(baseline.retirement):
                pending = 2
            elif call[0] == "sync":
                sync_index += 1
                if pending:
                    offsets.append(sync_index); pending -= 1
        self.assertEqual(len(offsets), 2)
        for offset in offsets:
            with self.subTest(offset=offset):
                fixture = self.fixture()
                current = self.current_identity(fixture); evidence = self.evidence(fixture)
                target = fixture.state()["syncs"] + offset
                fixture.retire(extra_env={"MVO_FAIL_AFTER_SYNC": str(target)}, success=False)
                self.assertEqual(fixture.state()["syncs"], target)
                archive = fixture.archives()["retirement"]
                self.assertTrue(archive.is_dir())
                self.assertFalse(fixture.retirement.exists())
                self.assertFalse((archive / "confirmation").exists())
                before = fixture.full_tree(); calls = fixture.service_mutations()
                for action in (lambda: fixture.upgrade_to_c(success=False),
                               lambda: fixture.observe("uninstall", success=False),
                               lambda: fixture.observe("uninstall", "--remove-credentials", success=False),
                               lambda: fixture.retire(retirement_id=OTHER_RETIREMENT_ID, success=False)):
                    action()
                    self.assertEqual(fixture.full_tree(), before)
                    self.assertEqual(fixture.service_mutations(), calls)
                self.finish_interrupted(fixture, evidence, current)

    def test_second_resume_interruption_preserves_prior_record_recovery_evidence(self):
        fixture = self.fixture()
        current = self.current_identity(fixture); evidence = self.evidence(fixture)
        # The first move publishes the staged prepared directory; the following
        # record publication can be interrupted before it replaces prepared.
        fixture.retire(extra_env={"MVO_FAIL_MOVE": str(fixture.state()["moves"] + 2)}, success=False)
        self.assertTrue((fixture.retirement / "record.next").is_file())
        fixture.retire(resume=True, extra_env={"MVO_FAIL_AFTER_MOVE": str(fixture.state()["moves"] + 1)},
                       success=False)
        records = {path.name: fixture.path_identity(path)
                   for path in fixture.retirement.glob("recovery-*")}
        self.assertTrue(records)
        self.finish_interrupted(fixture, evidence, current)
        archive = fixture.archives()["retirement"]
        for name, identity in records.items():
            self.assertEqual(fixture.path_identity(archive / name), identity)

    def test_partial_prepared_directory_is_preserved_and_never_promoted(self):
        for kind in ("empty", "partial", "foreign-current", "foreign-retirement"):
            with self.subTest(kind=kind):
                fixture = self.fixture()
                target = fixture.state()["moves"] + 1
                fixture.retire(extra_env={"MVO_FAIL_MOVE": str(target)}, success=False)
                self.assertEqual(fixture.state()["moves"], target)
                record = fixture.retirement_next / "record"
                self.assertTrue(record.is_file())
                data = record.read_bytes()
                if kind == "empty": record.unlink()
                elif kind == "partial": record.write_bytes(data[:-1])
                elif kind == "foreign-current": record.write_bytes(self.field(data, "current", "0" * 64))
                else: record.write_bytes(self.field(data, "retirement-id", OTHER_RETIREMENT_ID))
                self.assert_resume_refuses_without_mutation(fixture)

    def test_next_record_partial_duplicate_gap_foreign_ids_and_oversize_refuse(self):
        changes = {
            "partial": lambda data: data[:-1],
            "duplicate": lambda data: data + b"phase=stop\n",
            "phase-gap": lambda data: self.field(data, "phase", "journals"),
            "wrong-vm": lambda data: self.field(data, "vm-id", OTHER_VM_ID),
            "wrong-current": lambda data: self.field(data, "current", "0" * 64),
            "wrong-retirement": lambda data: self.field(data, "retirement-id", OTHER_RETIREMENT_ID),
            "wrong-inode": lambda data: self.field(data, "current-program-inode", "0:0"),
            "oversized": lambda data: data + b"x" * 2049,
        }
        for name, mutate in changes.items():
            with self.subTest(kind=name):
                fixture = self.prepared_record_interruption()
                record = fixture.retirement / "record.next"
                record.write_bytes(mutate(record.read_bytes()))
                self.assert_resume_refuses_without_mutation(fixture)

    def test_current_record_symlink_hardlink_permissions_and_unknown_names_refuse(self):
        for kind in ("symlink", "hardlink", "permissions", "unknown-name"):
            with self.subTest(kind=kind):
                fixture = self.prepared_record_interruption()
                record = fixture.retirement / "record"
                external = None
                if kind in ("symlink", "hardlink"):
                    external = fixture.base / "external-retirement-record"
                    external.write_bytes(record.read_bytes()); external.chmod(0o600)
                    record.unlink()
                    if kind == "symlink": record.symlink_to(external)
                    else: os.link(external, record)
                elif kind == "permissions": record.chmod(0o660)
                else: (fixture.retirement / "unrelated-preserved-evidence").write_bytes(b"keep this file\n")
                outside = fixture.path_identity(external) if external else None
                self.assert_resume_refuses_without_mutation(fixture)
                if external: self.assertEqual(fixture.path_identity(external), outside)

    def test_wrong_resume_pins_do_not_consume_valid_staged_record(self):
        fixture = self.prepared_record_interruption()
        for arguments in ({"vm_id": OTHER_VM_ID}, {"current": "0" * 64},
                          {"failed": "0" * 64}, {"retirement_id": OTHER_RETIREMENT_ID}):
            with self.subTest(arguments=arguments):
                self.assert_resume_refuses_without_mutation(fixture, **arguments)
        fixture.retire(resume=True)
        self.assertFalse(fixture.retirement.exists())

    def test_ambiguous_missing_or_double_generation_and_cohort_locations_refuse(self):
        baseline, trace = self.retirement_trace()
        moves = [call for call in trace if call[0] == "mv"]
        names = {"program": baseline.slot(baseline.program, "failed"),
                 "state": baseline.slot(baseline.owned_state, "failed"), "journals": baseline.journal.parent}
        offsets = {name: next(index for index, call in enumerate(moves, 1) if call[1] == str(path))
                   for name, path in names.items()}
        for name, offset in offsets.items():
            for kind in ("missing", "double"):
                with self.subTest(name=name, kind=kind):
                    fixture = self.fixture()
                    fixture.retire(extra_env={"MVO_FAIL_AFTER_MOVE": str(fixture.state()["moves"] + offset)}, success=False)
                    archive = fixture.archives()[name]
                    self.assertTrue(archive.is_dir())
                    if kind == "missing": shutil.rmtree(archive)
                    else:
                        source = {"program": fixture.slot(fixture.program, "failed"),
                                  "state": fixture.slot(fixture.owned_state, "failed"),
                                  "journals": fixture.journal.parent}[name]
                        shutil.copytree(archive, source)
                    self.assert_resume_refuses_without_mutation(fixture)

    def test_archived_b_executable_still_blocks_resume_after_program_rename(self):
        baseline, trace = self.retirement_trace()
        offset = next(index for index, call in enumerate((call for call in trace if call[0] == "mv"), 1)
                      if call[1] == str(baseline.slot(baseline.program, "failed")))
        fixture = self.fixture()
        current = self.current_identity(fixture); evidence = self.evidence(fixture)
        target = fixture.state()["moves"] + offset
        fixture.retire(extra_env={"MVO_FAIL_AFTER_MOVE": str(target)}, success=False)
        self.assertEqual(fixture.state()["moves"], target)
        executable = fixture.archives()["program"] / "macopenvm-agent"
        self.assertTrue(executable.is_file())
        process = fixture.process(executable=executable, cmdline=b"archived-root-agent\0")
        before = fixture.full_tree(); moves = fixture.state()["moves"]
        fixture.retire(resume=True, success=False)
        self.assertEqual(fixture.full_tree(), before)
        self.assertEqual(fixture.state()["moves"], moves)
        self.assertEqual(self.current_identity(fixture), current)
        self.assert_evidence_preserved(fixture, evidence)
        shutil.rmtree(process)
        self.finish_interrupted(fixture, evidence, current)

    def test_false_stop_ack_and_live_uid_agent_supervisor_or_unreadable_status_refuse(self):
        for kind in ("false-ack", "service-uid", "root-failed-agent", "root-supervisor", "unreadable-status"):
            with self.subTest(kind=kind):
                fixture = self.fixture()
                current = self.current_identity(fixture); evidence = self.evidence(fixture)
                environment = {}
                if kind == "false-ack": environment["MVO_FALSE_STOP_ACK"] = "1"
                elif kind == "service-uid": fixture.process(uid=444, executable=fixture.commands / "id", cmdline=b"id\0")
                elif kind == "root-failed-agent": fixture.process(executable=fixture.slot(fixture.program, "failed") / "macopenvm-agent", cmdline=b"agent\0")
                elif kind == "root-supervisor": fixture.process(executable=fixture.commands / "supervise-daemon", cmdline=b"supervise-daemon\0macopenvm-agent\0--reexec\0")
                else:
                    process = fixture.process(executable=fixture.commands / "id", cmdline=b"id\0")
                    environment["MVO_FAIL_DD_INPUT"] = str(process / "status")
                offset = len(fixture.state()["calls"])
                fixture.retire(extra_env=environment, success=False)
                self.assertEqual(self.current_identity(fixture), current)
                self.assert_evidence_preserved(fixture, evidence)
                self.assertFalse(fixture.archives()["program"].exists())
                self.assertFalse(fixture.archives()["state"].exists())
                self.assertFalse(any(call[:3] == ["rc-service", "macopenvm-agent", "start"]
                                     for call in fixture.state()["calls"][offset:]))

    def test_each_selected_source_device_mismatch_refuses_without_copy_fallback(self):
        for name in ("prepared-directory", "record-next", "failed-program", "failed-state", "cohort"):
            with self.subTest(source=name):
                fixture = self.fixture()
                current = self.current_identity(fixture); evidence = self.evidence(fixture)
                source = {"prepared-directory": fixture.retirement_next,
                          "record-next": fixture.retirement / "record.next",
                          "failed-program": fixture.slot(fixture.program, "failed"),
                          "failed-state": fixture.slot(fixture.owned_state, "failed"),
                          "cohort": fixture.journal.parent}[name]
                copies = fixture.state().get("copies", 0)
                fixture.retire(extra_env={"MVO_OTHER_DEVICE_PATH": str(source)}, success=False)
                self.assertEqual(fixture.state().get("copies", 0), copies)
                self.assertEqual(self.current_identity(fixture), current)
                self.assert_evidence_preserved(fixture, evidence)
                self.finish_interrupted(fixture, evidence, current)

    def test_archived_content_links_permissions_or_unrelated_names_block_future_mutation(self):
        for kind in ("agent-bytes", "cohort-bytes", "record-bytes", "confirmation-symlink",
                     "agent-hardlink", "archive-permissions", "unrelated-name"):
            with self.subTest(kind=kind):
                fixture = self.fixture()
                fixture.retire()
                archive = fixture.archives()
                external = None
                if kind == "agent-bytes":
                    path = archive["program"] / "macopenvm-agent"
                    path.write_bytes(path.read_bytes() + b"changed\n")
                elif kind == "cohort-bytes":
                    path = archive["journals"] / "transaction"
                    path.write_bytes(self.field(path.read_bytes(), "source", "0" * 64))
                elif kind == "record-bytes":
                    path = archive["retirement"] / "record"
                    path.write_bytes(self.field(path.read_bytes(), "failed-program-inode", "0:0"))
                elif kind == "confirmation-symlink":
                    path = archive["retirement"] / "confirmation"
                    external = fixture.base / "external-confirmation"
                    external.write_bytes(path.read_bytes()); external.chmod(0o600)
                    path.unlink(); path.symlink_to(external)
                elif kind == "agent-hardlink":
                    external = fixture.base / "external-agent"
                    os.link(archive["program"] / "macopenvm-agent", external)
                elif kind == "archive-permissions": archive["retirement"].chmod(0o770)
                else: (archive["retirement"] / "unrelated-evidence").write_bytes(b"must remain\n")
                before = fixture.full_tree(); calls = fixture.service_mutations()
                outside = fixture.path_identity(external) if external else None
                fixture.upgrade_to_c(success=False)
                self.assertEqual(fixture.full_tree(), before)
                self.assertEqual(fixture.service_mutations(), calls)
                if external: self.assertEqual(fixture.path_identity(external), outside)

    def test_partial_or_foreign_confirmation_next_never_clears_unconfirmed_marker(self):
        baseline, trace = self.retirement_trace()
        moves = [call for call in trace if call[0] == "mv"]
        offset = next(index for index, call in enumerate(moves, 1)
                      if Path(call[1]).name == "confirmation.next")
        for kind in ("partial-next", "foreign-next", "partial-marker", "missing-record"):
            with self.subTest(kind=kind):
                fixture = self.fixture()
                target = fixture.state()["moves"] + offset
                fixture.retire(extra_env={"MVO_FAIL_MOVE": str(target)}, success=False)
                self.assertEqual(fixture.state()["moves"], target)
                archive = fixture.archives()["retirement"]
                next_record = archive / "confirmation.next"
                marker = archive / "confirmation-unconfirmed"
                self.assertTrue(next_record.is_file() and marker.is_file())
                if kind == "partial-next": next_record.write_bytes(next_record.read_bytes()[:-1])
                elif kind == "foreign-next": next_record.write_bytes(self.field(next_record.read_bytes(), "retirement-id", OTHER_RETIREMENT_ID))
                elif kind == "partial-marker": marker.write_bytes(marker.read_bytes()[:-1])
                else: (archive / "record").unlink()
                self.assert_resume_refuses_without_mutation(fixture)

    def test_confirmation_publication_fault_keeps_marker_until_explicit_flush_resume(self):
        baseline, trace = self.retirement_trace()
        moves = [call for call in trace if call[0] == "mv"]
        offset = next(index for index, call in enumerate(moves, 1)
                      if Path(call[1]).name == "confirmation.next")
        fixture = self.fixture()
        current = self.current_identity(fixture); evidence = self.evidence(fixture)
        target = fixture.state()["moves"] + offset
        fixture.retire(extra_env={"MVO_FAIL_AFTER_MOVE": str(target)}, success=False)
        self.assertEqual(fixture.state()["moves"], target)
        archive = fixture.archives()["retirement"]
        self.assertTrue((archive / "confirmation").is_file())
        self.assertTrue((archive / "confirmation-unconfirmed").is_file())
        before = fixture.full_tree(); calls = fixture.service_mutations()
        fixture.upgrade_to_c(success=False)
        self.assertEqual(fixture.full_tree(), before)
        self.assertEqual(fixture.service_mutations(), calls)
        self.finish_interrupted(fixture, evidence, current)

    def test_full_eight_genuine_archive_sets_refuse_ninth_without_pruning(self):
        fixture = self.fixture()
        protected = fixture.protected(); kernel = fixture.path_identity(fixture.kernel_lock)
        retired = {}
        for number in range(1, 9):
            retirement_id = f"{number:08x}-2222-4333-8444-{number:012x}"
            if number > 1:
                fixture.upgrade(); fixture.rollback()
            evidence = self.evidence(fixture); current = self.current_identity(fixture)
            fixture.retire(retirement_id=retirement_id)
            self.assert_complete(fixture, evidence, current, retirement_id)
            retired[retirement_id] = {name: self.tree_identity(fixture, path)
                                      for name, path in fixture.archives(retirement_id).items()}
        self.assertEqual(len(list(fixture.program_retired.iterdir())), 8)
        self.assertEqual(len(list(fixture.state_retired.iterdir())), 8)
        fixture.upgrade(); fixture.rollback()
        before = fixture.full_tree(); calls = fixture.service_mutations()
        fixture.retire(retirement_id=OTHER_RETIREMENT_ID, success=False)
        self.assertEqual(fixture.full_tree(), before)
        self.assertEqual(fixture.service_mutations(), calls)
        self.assertEqual(fixture.protected(), protected)
        self.assertEqual(fixture.path_identity(fixture.kernel_lock), kernel)
        for retirement_id, identities in retired.items():
            self.assertEqual({name: self.tree_identity(fixture, path)
                              for name, path in fixture.archives(retirement_id).items()}, identities)



if __name__ == "__main__":
    unittest.main()
