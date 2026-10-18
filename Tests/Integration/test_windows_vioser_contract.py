# SPDX-License-Identifier: Apache-2.0
"""Portable byte/ownership contracts; never imports Win32 or opens a device."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "GuestAgent/Windows/vioser_info_contract.h"
CLANG = Path("/usr/bin/clang")

C_FIXTURE = r'''
#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "vioser_info_contract.h"

static const char intended[] = "org.macOpenVM.info-test";
static size_t packet(uint8_t *out, const char *name, size_t length, size_t padding) {
    assert(length <= 256u && 8u + length + padding <= 1024u);
    memset(out, 0, 1024u);
    out[0] = 0x78u; out[1] = 0x56u; out[2] = 0x34u; out[3] = 0x12u;
    out[4] = 0u; out[5] = 1u; out[6] = 0u;
    memcpy(out + 7u, name, length);
    return 8u + length + padding;
}
static enum mvo_vioser_parse_result parse(uint8_t *bytes, size_t count, bool canonical, mvo_vioser_info *out) {
    return mvo_vioser_parse_info(bytes, count, intended, sizeof(intended) - 1u, canonical, out);
}

static void padded_unaligned_packet(void) {
    uint8_t storage[1025];
    uint8_t *bytes = storage + 1u;
    size_t count = packet(bytes, intended, sizeof(intended) - 1u, 41u);
    mvo_vioser_info info;
    assert(parse(bytes, count, true, &info) == MVO_VIOSER_MATCH);
    assert(info.id == UINT32_C(0x12345678));
    assert(!info.out_full && info.host_connected && !info.guest_connected);
    /* Padding is outside the first terminated name, including the producer's extra byte. */
    assert(parse(bytes, count - 40u, true, &info) == MVO_VIOSER_MATCH);
    assert(parse(bytes, 1024u, true, &info) == MVO_VIOSER_MATCH);
}
static void returned_count_bounds(void) {
    uint8_t bytes[1025];
    packet(bytes, intended, sizeof(intended) - 1u, 0u);
    mvo_vioser_info info;
    for (size_t count = 0; count < 8u; ++count) assert(parse(bytes, count, false, &info) == MVO_VIOSER_INVALID);
    assert(parse(bytes, 1025u, false, &info) == MVO_VIOSER_INVALID);
    assert(parse(bytes, SIZE_MAX, false, &info) == MVO_VIOSER_INVALID);
    /* An allocated NUL outside the returned count cannot terminate the response. */
    assert(parse(bytes, 7u + sizeof(intended) - 1u, false, &info) == MVO_VIOSER_INVALID);
}
static void argument_bounds(void) {
    uint8_t bytes[1024];
    size_t count = packet(bytes, intended, sizeof(intended) - 1u, 0u);
    mvo_vioser_info info;
    assert(mvo_vioser_parse_info(NULL, count, intended, sizeof(intended) - 1u, false, &info) == MVO_VIOSER_INVALID);
    assert(mvo_vioser_parse_info(bytes, count, NULL, 1u, false, &info) == MVO_VIOSER_INVALID);
    assert(mvo_vioser_parse_info(bytes, count, intended, sizeof(intended) - 1u, false, NULL) == MVO_VIOSER_INVALID);
    assert(mvo_vioser_parse_info(bytes, count, intended, 0u, false, &info) == MVO_VIOSER_INVALID);
    assert(mvo_vioser_parse_info(bytes, count, intended, 256u, false, &info) == MVO_VIOSER_INVALID);
}
static void name_extent_bounds(void) {
    uint8_t bytes[1024];
    char maximum[256];
    memset(maximum, 'P', 255u); maximum[255] = '\0';
    size_t count = packet(bytes, maximum, 255u, 0u);
    mvo_vioser_info info;
    assert(mvo_vioser_parse_info(bytes, count, maximum, 255u, false, &info) == MVO_VIOSER_MATCH);
    bytes[7u + 255u] = 'P'; bytes[7u + 256u] = 0u;
    assert(mvo_vioser_parse_info(bytes, count + 1u, maximum, 255u, false, &info) == MVO_VIOSER_INVALID);
    memset(bytes + 7u, 'P', 1017u);
    assert(parse(bytes, 1024u, false, &info) == MVO_VIOSER_INVALID);
}
static void exact_name_only(void) {
    uint8_t bytes[1024];
    mvo_vioser_info info;
    size_t count = packet(bytes, intended, sizeof(intended) - 1u, 0u);
    bytes[7u] = 'O';
    assert(parse(bytes, count, false, &info) == MVO_VIOSER_OTHER);
    packet(bytes, intended, sizeof(intended) - 1u, 0u);
    bytes[7u + sizeof(intended) - 1u] = '-'; bytes[8u + sizeof(intended) - 1u] = 0u;
    assert(parse(bytes, count + 1u, false, &info) == MVO_VIOSER_OTHER);
    packet(bytes, intended, sizeof(intended) - 1u, 0u);
    bytes[10u] = 0u;
    assert(parse(bytes, count, false, &info) == MVO_VIOSER_OTHER);
    count = packet(bytes, "", 0u, 0u);
    assert(parse(bytes, count, false, &info) == MVO_VIOSER_OTHER);
}
static void source_specific_boolean_policy(void) {
    uint8_t bytes[1024];
    size_t count = packet(bytes, intended, sizeof(intended) - 1u, 0u);
    mvo_vioser_info info;
    bytes[4] = 2u; bytes[5] = 128u; bytes[6] = 255u;
    assert(parse(bytes, count, false, &info) == MVO_VIOSER_MATCH);
    assert(info.out_full && info.host_connected && info.guest_connected);
    assert(parse(bytes, count, true, &info) == MVO_VIOSER_INVALID);
}
static void unique_match_and_sticky_failure(void) {
    mvo_vioser_scan scan = {0};
    assert(!mvo_vioser_scan_unique(&scan));
    assert(mvo_vioser_scan_admit(&scan));
    assert(mvo_vioser_scan_record(&scan, MVO_VIOSER_OTHER));
    assert(!mvo_vioser_scan_unique(&scan));
    assert(mvo_vioser_scan_admit(&scan));
    assert(mvo_vioser_scan_record(&scan, MVO_VIOSER_MATCH));
    assert(mvo_vioser_scan_unique(&scan));
    assert(mvo_vioser_scan_admit(&scan));
    assert(!mvo_vioser_scan_record(&scan, MVO_VIOSER_MATCH));
    assert(scan.failed && !mvo_vioser_scan_unique(&scan));
    assert(!mvo_vioser_scan_record(&scan, MVO_VIOSER_OTHER));
    mvo_vioser_scan malformed = {0};
    assert(mvo_vioser_scan_admit(&malformed));
    assert(!mvo_vioser_scan_record(&malformed, MVO_VIOSER_INVALID));
    assert(!mvo_vioser_scan_record(&malformed, MVO_VIOSER_MATCH));
    assert(!mvo_vioser_scan_unique(&malformed));
}
static void discovery_limit(void) {
    mvo_vioser_scan scan = {0};
    for (unsigned index = 0; index < 32u; ++index) {
        assert(mvo_vioser_scan_admit(&scan));
        assert(mvo_vioser_scan_record(&scan, index == 31u ? MVO_VIOSER_MATCH : MVO_VIOSER_OTHER));
    }
    assert(scan.examined == 32u && mvo_vioser_scan_unique(&scan));
    assert(!mvo_vioser_scan_admit(&scan));
    assert(scan.failed && !mvo_vioser_scan_unique(&scan));
    mvo_vioser_scan overflow = {.examined = UINT_MAX};
    assert(!mvo_vioser_scan_admit(&overflow));
    assert(overflow.examined == UINT_MAX);
}
static void cancel_results_never_complete(void) {
    const unsigned cancel_results[] = {1u, 2u, 3u, 1168u};
    for (size_t index = 0; index < sizeof(cancel_results) / sizeof(cancel_results[0]); ++index) {
        mvo_vioser_operation op;
        mvo_vioser_op_init(&op);
        assert(mvo_vioser_op_can_release(&op) && !mvo_vioser_op_success(&op));
        mvo_vioser_op_submit(&op);
        assert(!mvo_vioser_op_can_release(&op));
        mvo_vioser_op_submit(&op); /* Duplicate submission cannot manufacture completion. */
        mvo_vioser_op_request_cancel(&op, true, false);
        mvo_vioser_op_cancel_result(&op, cancel_results[index]);
        assert(op.cancel_result == cancel_results[index]);
        assert(!op.completed && !mvo_vioser_op_can_release(&op) && !mvo_vioser_op_success(&op));
        mvo_vioser_op_complete(&op, false); /* Actual aborted completion, not cancellation ACK. */
        assert(mvo_vioser_op_can_release(&op) && !mvo_vioser_op_success(&op));
    }
}
static void late_success_cannot_clear_deadline_or_user_cancel(void) {
    for (unsigned kind = 0; kind < 3u; ++kind) {
        mvo_vioser_operation op;
        mvo_vioser_op_init(&op); mvo_vioser_op_submit(&op);
        mvo_vioser_op_request_cancel(&op, kind != 1u, kind != 0u);
        mvo_vioser_op_cancel_result(&op, 1168u); /* ERROR_NOT_FOUND may race normal completion. */
        mvo_vioser_op_request_cancel(&op, false, false);
        assert(!mvo_vioser_op_can_release(&op));
        mvo_vioser_op_complete(&op, true);
        assert(mvo_vioser_op_can_release(&op) && !mvo_vioser_op_success(&op));
        assert(op.deadline_expired || op.user_cancelled);
    }
}
static void actual_completion_and_new_operation(void) {
    mvo_vioser_operation op;
    mvo_vioser_op_init(&op); mvo_vioser_op_submit(&op);
    mvo_vioser_op_complete(&op, true);
    assert(mvo_vioser_op_can_release(&op) && mvo_vioser_op_success(&op));
    /* Reinitialization is valid only after the previous operation actually settled. */
    mvo_vioser_op_init(&op); mvo_vioser_op_submit(&op);
    assert(!mvo_vioser_op_can_release(&op) && !mvo_vioser_op_success(&op));
    mvo_vioser_op_complete(&op, false);
    assert(mvo_vioser_op_can_release(&op) && !mvo_vioser_op_success(&op));
}
static void incomplete_status_even_with_spurious_completion_hint(void) {
    const uint32_t not_complete[] = {996u, 997u, 258u, 192u};
    for (size_t index = 0; index < sizeof(not_complete) / sizeof(not_complete[0]); ++index) {
        for (unsigned hint = 0; hint < 2u; ++hint) {
            mvo_vioser_operation op;
            mvo_vioser_op_init(&op); mvo_vioser_op_submit(&op);
            assert(!mvo_vioser_op_observe(&op, false, not_complete[index], hint != 0u));
            assert(!mvo_vioser_op_can_release(&op) && !mvo_vioser_op_success(&op));
            mvo_vioser_op_request_cancel(&op, true, false);
            mvo_vioser_op_cancel_result(&op, 2u);
            assert(!mvo_vioser_op_observe(&op, false, not_complete[index], true));
            assert(!mvo_vioser_op_can_release(&op));
            assert(mvo_vioser_op_observe(&op, true, 0u, false));
            assert(mvo_vioser_op_can_release(&op) && !mvo_vioser_op_success(&op));
        }
    }
}
static void failed_result_needs_actual_terminal_flag(void) {
    const uint32_t errors[] = {995u, 6u, 1117u};
    for (size_t index = 0; index < sizeof(errors) / sizeof(errors[0]); ++index) {
        mvo_vioser_operation op;
        mvo_vioser_op_init(&op); mvo_vioser_op_submit(&op);
        assert(!mvo_vioser_op_observe(&op, false, errors[index], false));
        assert(!mvo_vioser_op_can_release(&op));
        assert(mvo_vioser_op_observe(&op, false, errors[index], true));
        assert(mvo_vioser_op_can_release(&op) && !mvo_vioser_op_success(&op));
    }
    mvo_vioser_operation success;
    mvo_vioser_op_init(&success); mvo_vioser_op_submit(&success);
    assert(mvo_vioser_op_observe(&success, true, 0u, false));
    assert(mvo_vioser_op_can_release(&success) && mvo_vioser_op_success(&success));
}
int main(int argc, char **argv) {
    assert(argc == 2);
    switch (atoi(argv[1])) {
        case 1: padded_unaligned_packet(); break;
        case 2: returned_count_bounds(); break;
        case 3: argument_bounds(); break;
        case 4: name_extent_bounds(); break;
        case 5: exact_name_only(); break;
        case 6: source_specific_boolean_policy(); break;
        case 7: unique_match_and_sticky_failure(); break;
        case 8: discovery_limit(); break;
        case 9: cancel_results_never_complete(); break;
        case 10: late_success_cannot_clear_deadline_or_user_cancel(); break;
        case 11: actual_completion_and_new_operation(); break;
        case 12: incomplete_status_even_with_spurious_completion_hint(); break;
        case 13: failed_result_needs_actual_terminal_flag(); break;
        default: abort();
    }
    return 0;
}
'''


@unittest.skipUnless(CLANG.is_file(), "Requires an existing native Clang for portable C contracts.")
class WindowsVioserContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="mvo-vioser-contract-", dir="/private/tmp")
        cls.addClassCleanup(cls.temporary.cleanup)
        base = Path(cls.temporary.name)
        header = HEADER.read_bytes()
        cls.header_sha = hashlib.sha256(header).hexdigest()
        (base / HEADER.name).write_bytes(header)
        source = base / "fixture.c"
        source.write_text(C_FIXTURE)
        cls.binary = base / "fixture"
        build = subprocess.run([str(CLANG), "-std=c11", "-Wall", "-Wextra", "-Wconversion", "-Werror",
                                "-pedantic", str(source), "-o", str(cls.binary)],
                               capture_output=True, timeout=20, check=False)
        if build.returncode != 0:
            raise AssertionError(build.stderr.decode())
        if hashlib.sha256(HEADER.read_bytes()).hexdigest() != cls.header_sha:
            raise AssertionError("Portable contract source changed during compilation.")

    def check_case(self, number):
        result = subprocess.run([str(self.binary), str(number)], capture_output=True, timeout=5, check=False)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, b"")

    def test_padded_unaligned_exact_name_and_little_endian_id(self): self.check_case(1)
    def test_only_returned_bytes_can_supply_header_and_nul(self): self.check_case(2)
    def test_null_outputs_and_expected_name_bounds(self): self.check_case(3)
    def test_name_termination_and_maximum_extent(self): self.check_case(4)
    def test_prefix_case_and_embedded_nul_are_not_matches(self): self.check_case(5)
    def test_nonzero_boolean_semantics_and_explicit_stricter_policy(self): self.check_case(6)
    def test_duplicate_or_invalid_metadata_permanently_rejects_scan(self): self.check_case(7)
    def test_interface_limit_does_not_wrap_or_leave_unique_match(self): self.check_case(8)
    def test_cancel_ack_not_found_and_error_never_release_pending_operation(self): self.check_case(9)
    def test_late_success_cannot_clear_deadline_or_user_cancellation(self): self.check_case(10)
    def test_release_requires_actual_completion_before_new_operation(self): self.check_case(11)
    def test_incomplete_pending_timeout_or_apc_do_not_release_even_with_completion_hint(self): self.check_case(12)
    def test_failed_overlapped_result_needs_real_terminal_flag(self): self.check_case(13)


if __name__ == "__main__":
    unittest.main()
