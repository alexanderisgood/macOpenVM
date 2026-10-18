/* SPDX-License-Identifier: Apache-2.0 */
/* Original shared evaluator primitives; fixed private scope, not a service API. */
#ifndef MVO_VIOSER_WIN32_LAB_H
#define MVO_VIOSER_WIN32_LAB_H
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <setupapi.h>
#include <winioctl.h>
#include <stddef.h>
#include "vioser_info_contract.h"

typedef struct { UINT id; BOOLEAN out_full, host_connected, guest_connected; CHAR name[1]; } mvo_port_abi;
_Static_assert(sizeof(void *) == 8 && sizeof(long) == 4 && sizeof(WCHAR) == 2, "Windows ARM64 LLP64");
_Static_assert(sizeof(OVERLAPPED) == 32 && offsetof(OVERLAPPED, hEvent) == 24, "OVERLAPPED ABI");
_Static_assert(sizeof(SP_DEVICE_INTERFACE_DATA) == 32, "interface ABI");
_Static_assert(sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W) == 8 && offsetof(SP_DEVICE_INTERFACE_DETAIL_DATA_W, DevicePath) == 4, "detail ABI");
_Static_assert(sizeof(mvo_port_abi) == 8 && offsetof(mvo_port_abi, name) == 7, "port ABI");
_Static_assert(offsetof(mvo_port_abi, out_full) == 4 && offsetof(mvo_port_abi, host_connected) == 5 && offsetof(mvo_port_abi, guest_connected) == 6, "flag ABI");
_Static_assert(CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_OUT_DIRECT, FILE_ANY_ACCESS) == 0x222002, "current INFO IOCTL");

static const GUID port_guid = {0x6fde7521, 0x1b65, 0x48ae, {0xb6,0x28,0x80,0xbe,0x62,0x01,0x60,0x26}};
static const char intended_name[] = "org.macopenvm.agent.v1";
static union { SP_DEVICE_INTERFACE_DETAIL_DATA_W alignment; unsigned char bytes[8192]; } detail_buffer;
static unsigned char info_buffer[1024];
static OVERLAPPED operation;
static mvo_vioser_operation ownership;
static bool native_pending;
static HANDLE cancel_event;

void *memset(void *destination, int value, size_t count) {
    volatile unsigned char *out = destination;
    for (size_t index = 0; index < count; ++index) out[index] = (unsigned char)value;
    return destination;
}
void *memcpy(void *restrict destination, const void *restrict source, size_t count) {
    volatile unsigned char *out = destination;
    const unsigned char *in = source;
    for (size_t index = 0; index < count; ++index) out[index] = in[index];
    return destination;
}
static void marker(const char *text, DWORD length) {
    DWORD written = 0;
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    if (output != NULL && output != INVALID_HANDLE_VALUE) (void)WriteFile(output, text, length, &written, NULL);
}
#define MARK(text) marker(text "\r\n", (DWORD)(sizeof(text "\r\n") - 1u))
static BOOL WINAPI control(DWORD type) {
    /* CLOSE/logoff/OS shutdown retain the default OS policy; we cannot guarantee
     * cooperative cleanup for externally terminated processes. */
    if (type != CTRL_C_EVENT && type != CTRL_BREAK_EVENT) return FALSE;
    if (cancel_event != NULL) (void)SetEvent(cancel_event);
    return TRUE;
}
static bool complete(HANDLE port, DWORD *returned) {
    BOOL success = GetOverlappedResult(port, &operation, returned, FALSE);
    DWORD error = success ? ERROR_SUCCESS : GetLastError();
    return mvo_vioser_op_observe(&ownership, success != FALSE, error, native_pending && HasOverlappedIoCompleted(&operation));
}
static void retain_pending(HANDLE port, DWORD *returned) {
    MARK("mvo.vioser-info status=retained-pending-failure");
    while (!complete(port, returned)) {
        /* Reset plus a second completion check avoids losing a completion race. */
        if (!ResetEvent(operation.hEvent)) { Sleep(INFINITE); }
        if (complete(port, returned)) break;
        if (WaitForSingleObject(operation.hEvent, INFINITE) != WAIT_OBJECT_0) { Sleep(INFINITE); }
    }
}
static bool query(HANDLE port, ULONGLONG began, DWORD *returned) {
    memset(&operation, 0, sizeof(operation));
    memset(info_buffer, 0, sizeof(info_buffer));
    mvo_vioser_op_init(&ownership);
    operation.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (operation.hEvent == NULL) return false;
    mvo_vioser_op_submit(&ownership);
    BOOL issued = DeviceIoControl(port, 0x222002u, NULL, 0, info_buffer, sizeof(info_buffer), returned, &operation);
    DWORD initial_error = issued ? ERROR_SUCCESS : GetLastError();
    native_pending = !issued && initial_error == ERROR_IO_PENDING;
    if (issued) {
        DWORD actual = 0;
        BOOL obtained = GetOverlappedResult(port, &operation, &actual, FALSE);
        *returned = actual;
        mvo_vioser_op_complete(&ownership, obtained != FALSE);
    } else if (!native_pending) mvo_vioser_op_complete(&ownership, false);
    HANDLE events[2] = {operation.hEvent, cancel_event};
    while (!ownership.completed) {
        ULONGLONG elapsed = GetTickCount64() - began;
        bool stopped = WaitForSingleObject(cancel_event, 0) == WAIT_OBJECT_0;
        if (elapsed >= 10000u || stopped) mvo_vioser_op_request_cancel(&ownership, elapsed >= 10000u, stopped);
        if (complete(port, returned)) break;
        DWORD remaining = elapsed < 10000u ? (DWORD)(10000u - elapsed) : 0u;
        DWORD wait = stopped ? WAIT_OBJECT_0 + 1u : WaitForMultipleObjects(2, events, FALSE, remaining);
        if (wait == WAIT_OBJECT_0) {
            bool late = GetTickCount64() - began >= 10000u;
            bool interrupted = WaitForSingleObject(cancel_event, 0) == WAIT_OBJECT_0;
            if (late || interrupted) mvo_vioser_op_request_cancel(&ownership, late, interrupted);
            if (complete(port, returned)) break;
            /* A signaled event without completion is a retained failure, not a spin. */
        }
        bool user = wait == WAIT_OBJECT_0 + 1u;
        mvo_vioser_op_request_cancel(&ownership, !user, user);
        BOOL cancelled = CancelIoEx(port, &operation);
        mvo_vioser_op_cancel_result(&ownership, cancelled ? 1u : GetLastError() == ERROR_NOT_FOUND ? 2u : 3u);
        if (!complete(port, returned)) {
            (void)WaitForSingleObject(operation.hEvent, 2000u);
            if (!complete(port, returned)) retain_pending(port, returned);
        }
        break;
    }
    if (!mvo_vioser_op_can_release(&ownership)) retain_pending(port, returned);
    bool late = GetTickCount64() - began >= 10000u;
    bool interrupted = WaitForSingleObject(cancel_event, 0) == WAIT_OBJECT_0;
    if (late || interrupted) mvo_vioser_op_request_cancel(&ownership, late, interrupted);
    bool success = mvo_vioser_op_success(&ownership);
    if (!CloseHandle(operation.hEvent)) success = false;
    operation.hEvent = NULL;
    return success;
}


#endif
