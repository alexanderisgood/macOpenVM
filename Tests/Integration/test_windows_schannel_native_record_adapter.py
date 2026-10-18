# SPDX-License-Identifier: Apache-2.0
"""Compile the actual native adapter functions with SSPI descriptor fixtures.

No Windows API or cryptography executes. These cases check native observation
mapping, which the portable contract cannot establish on its own.
"""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "GuestAgent/Windows/schannel_credential_lab.c"
HEADERS = [ROOT / "GuestAgent/Windows/schannel_record_contract.h",
           ROOT / "GuestAgent/Windows/schannel_token_contract.h"]
CLANG = Path("/usr/bin/clang")

FIXTURE = r'''
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include "schannel_record_contract.h"
#include "schannel_token_contract.h"
/* Only the fields/types used by the extracted native functions are modeled.
 * Status values are fixture labels, never actual SSPI execution evidence. */
typedef uint32_t ULONG;
typedef int32_t SECURITY_STATUS;
typedef struct { uint64_t lower, upper; } CtxtHandle;
typedef struct { ULONG cbBuffer, BufferType; void *pvBuffer; } SecBuffer;
typedef struct { ULONG ulVersion, cBuffers; SecBuffer *pBuffers; } SecBufferDesc;
typedef struct { CtxtHandle context; mvo_schannel_tokens tokens; } endpoint;
#define SEC_E_OK 0
#define SEC_E_INCOMPLETE_MESSAGE (-1)
#define SEC_I_RENEGOTIATE 2
#define SEC_I_CONTEXT_EXPIRED 3
#define SEC_E_CONTEXT_EXPIRED (-4)
#define SECBUFFER_VERSION 0u
#define SECBUFFER_EMPTY 0u
#define SECBUFFER_DATA 1u
#define SECBUFFER_TOKEN 2u
#define SECBUFFER_MISSING 4u
#define SECBUFFER_EXTRA 5u
#define SECBUFFER_STREAM_TRAILER 6u
#define SECBUFFER_STREAM_HEADER 7u
static uint8_t record_decrypt[MVO_SCHANNEL_RECORD_LIMIT];
static mvo_schannel_record decrypted;
static SECURITY_STATUS native_status;
static unsigned scenario, calls;
static bool deadline;
static bool expired(void) { return deadline; }
static SECURITY_STATUS DecryptMessage(CtxtHandle *context, SecBufferDesc *message,
    ULONG sequence, ULONG *qop) {
    assert(context != NULL && sequence == 0u && qop == NULL);
    assert(message->ulVersion == SECBUFFER_VERSION && message->cBuffers == 4u);
    SecBuffer *b = message->pBuffers;
    assert(b[0].BufferType == SECBUFFER_DATA && b[0].pvBuffer == record_decrypt);
    for (unsigned i = 1u; i < 4u; ++i)
        assert(b[i].BufferType == SECBUFFER_EMPTY && b[i].cbBuffer == 0u && b[i].pvBuffer == NULL);
    ++calls;
    switch (scenario) {
        case 0u: /* Incomplete leaves DATA naming ciphertext, not plaintext. */
            b[1] = (SecBuffer){3u, SECBUFFER_MISSING, NULL};
            return SEC_E_INCOMPLETE_MESSAGE;
        case 1u:
            record_decrypt[7] ^= 0x80u;
            return SEC_I_RENEGOTIATE;
        case 2u: return SEC_I_CONTEXT_EXPIRED;
        case 3u: return -99;
        case 4u: /* Actual OK maps only the owned consumed DATA prefix. */
            memcpy(record_decrypt + 5u, decrypted.fixed, decrypted.fixed_count);
            b[0] = (SecBuffer){5u, SECBUFFER_STREAM_HEADER, record_decrypt};
            b[1] = (SecBuffer){(ULONG)decrypted.fixed_count, SECBUFFER_DATA, record_decrypt + 5u};
            b[2] = (SecBuffer){7u, SECBUFFER_STREAM_TRAILER, record_decrypt + 5u + decrypted.fixed_count};
            return SEC_E_OK;
        case 5u: /* An unrelated pointer must never reach payload comparison. */
            b[0] = (SecBuffer){(ULONG)decrypted.fixed_count, SECBUFFER_DATA, (void *)(uintptr_t)UINTPTR_MAX};
            return SEC_E_OK;
        case 6u:
            b[1] = (SecBuffer){1u, SECBUFFER_EXTRA, NULL};
            b[2] = (SecBuffer){1u, SECBUFFER_EXTRA, NULL};
            return SEC_E_OK;
        case 7u:
            for (unsigned i = 0u; i < 4u; ++i) b[i] = (SecBuffer){0u, SECBUFFER_EMPTY, NULL};
            b[1] = (SecBuffer){3u, SECBUFFER_EXTRA, NULL};
            return SEC_E_OK;
        case 8u:
            b[1] = (SecBuffer){0u, 999u, NULL};
            return SEC_E_INCOMPLETE_MESSAGE;
        case 9u: deadline = true; return SEC_E_INCOMPLETE_MESSAGE;
        case 10u:
            b[0].pvBuffer = (void *)(uintptr_t)UINTPTR_MAX;
            return SEC_I_RENEGOTIATE;
        default: assert(false); return -99;
    }
}
'''

CASES = r'''
int main(int argc, char **argv) {
    assert(argc == 2);
    scenario = (unsigned)strtoul(argv[1], NULL, 10);
    endpoint side = {0};
    mvo_schannel_init(&side.tokens);
    assert(mvo_record_init(&decrypted, record_decrypt, sizeof(record_decrypt),
        5u, 7u, 4096u, true, true));
    uint8_t input[64];
    memset(input, 0x5a, sizeof(input));
    assert(mvo_record_append(&decrypted, input, sizeof(input)));
    enum mvo_schannel_record_outcome outcome = decrypt_once(&side);
    assert(calls == 1u && !decrypted.pending && mvo_record_can_release(&decrypted));
    switch (scenario) {
        case 0u:
            assert(outcome == MVO_RECORD_NEED_INPUT && !decrypted.failed && !decrypted.plaintext_done);
            assert(decrypted.input_count == sizeof(input) && memcmp(record_decrypt, input, sizeof(input)) == 0);
            assert(decrypted.retry_count == sizeof(input));
            break;
        case 1u:
            assert(outcome == MVO_RECORD_REHANDSHAKE && decrypted.failed && side.tokens.cancelled);
            input[7] ^= 0x80u;
            assert(decrypted.input_count == sizeof(input) && memcmp(record_decrypt, input, sizeof(input)) == 0);
            break;
        case 2u: assert(outcome == MVO_RECORD_CLOSED && !decrypted.plaintext_done); break;
        case 4u: assert(outcome == MVO_RECORD_PLAINTEXT && decrypted.plaintext_done); break;
        case 7u:
            assert(outcome == MVO_RECORD_CONTROL && decrypted.input_count == 3u && !decrypted.plaintext_done);
            assert(memcmp(record_decrypt, input + sizeof(input) - 3u, 3u) == 0);
            break;
        default: assert(outcome == MVO_RECORD_REJECTED && decrypted.failed && !decrypted.plaintext_done); break;
    }
    return 0;
}
'''


def native_functions(text):
    start = text.index("static enum mvo_schannel_record_status record_status(")
    stop = text.index("static bool record_exchange(", start)
    functions = text[start:stop]
    # stream_sizes depends on actual context queries and is separately required
    # by the Windows build. Keep record_status/decrypt_once exactly as authored.
    sizes_start = functions.index("static bool stream_sizes(")
    decrypt_start = functions.index("static enum mvo_schannel_record_outcome decrypt_once(")
    return functions[:sizes_start] + functions[decrypt_start:]


class NativeRecordAdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CLANG.is_file():
            raise unittest.SkipTest("actual adapter fixture needs the system C compiler")
        cls.paths = [SOURCE, *HEADERS]
        cls.pins = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in cls.paths}
        cls.temp = tempfile.TemporaryDirectory(prefix="mvo-native-record-adapter-")
        directory = Path(cls.temp.name)
        source = directory / "fixture.c"
        source.write_text(FIXTURE + native_functions(SOURCE.read_text()) + CASES)
        cls.binaries = []
        for name, extra in [("strict", []), ("sanitized", ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"])]:
            binary = directory / name
            command = [str(CLANG), "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-Wpedantic",
                       "-Wconversion", "-Wsign-conversion", *extra, "-I", str(HEADERS[0].parent),
                       str(source), "-o", str(binary)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if result.returncode or result.stdout or result.stderr:
                raise AssertionError(f"{name} compilation refused: {result.returncode}\n{result.stderr}")
            cls.binaries.append(binary)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()
        if any(hashlib.sha256(p.read_bytes()).hexdigest() != pin for p, pin in cls.pins.items()):
            raise AssertionError("native source/header changed during adapter fixtures")

    def check(self, case):
        for binary in self.binaries:
            with self.subTest(build=binary.name):
                result = subprocess.run([str(binary), str(case)], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "")

    def test_incomplete_data_stays_ciphertext(self): self.check(0)
    def test_renegotiate_keeps_modified_buffer(self): self.check(1)
    def test_context_expired_refuses_plaintext(self): self.check(2)
    def test_unknown_status_refuses_plaintext(self): self.check(3)
    def test_ok_owned_data_maps_fixed_payload(self): self.check(4)
    def test_unrelated_data_pointer_refused(self): self.check(5)
    def test_duplicate_extra_refused(self): self.check(6)
    def test_empty_control_preserves_extra(self): self.check(7)
    def test_unknown_buffer_type_refused(self): self.check(8)
    def test_deadline_after_native_return_refused(self): self.check(9)
    def test_non_ok_data_extent_refused(self): self.check(10)


if __name__ == "__main__":
    unittest.main(verbosity=2)
