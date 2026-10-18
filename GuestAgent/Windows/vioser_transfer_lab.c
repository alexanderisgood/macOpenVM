/* SPDX-License-Identifier: Apache-2.0 */
/* Original fixed public read-first fixture. No TLS, credential, service or health. */
#include "vioser_win32_lab.h"
#include "vioser_transfer_contract.h"

static WCHAR selected_path[4096];
static uint32_t selected_id;
static unsigned char transfer_buffer[4096];
static mvo_vioser_transfer transfer;
static OVERLAPPED transfer_operation;
static bool transfer_native_pending;

static bool discover(void) {
    HDEVINFO devices = SetupDiGetClassDevsW(&port_guid, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (devices == INVALID_HANDLE_VALUE) return false;
    mvo_vioser_scan scan = {0};
    ULONGLONG began = GetTickCount64();
    bool ended = false;
    for (DWORD index = 0; index <= 32u; ++index) {
        SP_DEVICE_INTERFACE_DATA data;
        memset(&data, 0, sizeof(data)); data.cbSize = sizeof(data);
        if (!SetupDiEnumDeviceInterfaces(devices, NULL, &port_guid, index, &data)) {
            ended = GetLastError() == ERROR_NO_MORE_ITEMS;
            if (!ended) scan.failed = true;
            break;
        }
        if (!mvo_vioser_scan_admit(&scan)) break;
        if (GetTickCount64() - began >= 10000u || WaitForSingleObject(cancel_event, 0) == WAIT_OBJECT_0) { scan.failed = true; break; }
        DWORD required = 0;
        BOOL first = SetupDiGetDeviceInterfaceDetailW(devices, &data, NULL, 0, &required, NULL);
        if (first || GetLastError() != ERROR_INSUFFICIENT_BUFFER || required < 8u || required > sizeof(detail_buffer.bytes) || (required & 1u) != 0u) { scan.failed = true; break; }
        memset(&detail_buffer, 0, sizeof(detail_buffer));
        SP_DEVICE_INTERFACE_DETAIL_DATA_W *detail = (SP_DEVICE_INTERFACE_DETAIL_DATA_W *)detail_buffer.bytes;
        detail->cbSize = sizeof(*detail);
        DWORD actual = 0;
        if (!SetupDiGetDeviceInterfaceDetailW(devices, &data, detail, required, &actual, NULL) || actual > required || actual < 8u || (actual & 1u) != 0u) { scan.failed = true; break; }
        size_t units = (actual - offsetof(SP_DEVICE_INTERFACE_DETAIL_DATA_W, DevicePath)) / sizeof(WCHAR);
        size_t length = 0;
        while (length < units && detail->DevicePath[length] != 0) ++length;
        if (length == 0u || length == units || length >= sizeof(selected_path) / sizeof(selected_path[0])) { scan.failed = true; break; }
        HANDLE port = CreateFileW(detail->DevicePath, 0, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
        if (port == INVALID_HANDLE_VALUE) { scan.failed = true; break; }
        DWORD returned = 0;
        bool valid = query(port, began, &returned);
        mvo_vioser_info information;
        enum mvo_vioser_parse_result parsed = valid ? mvo_vioser_parse_info(info_buffer, returned,
            intended_name, sizeof(intended_name) - 1u, false, &information) : MVO_VIOSER_INVALID;
        bool released = mvo_vioser_op_can_release(&ownership) && CloseHandle(port);
        if (!released || !mvo_vioser_scan_record(&scan, parsed)) { scan.failed = true; break; }
        if (parsed == MVO_VIOSER_MATCH) {
            memcpy(selected_path, detail->DevicePath, (length + 1u) * sizeof(WCHAR));
            selected_id = information.id;
        }
    }
    if (!SetupDiDestroyDeviceInfoList(devices)) scan.failed = true;
    return ended && mvo_vioser_scan_unique(&scan);
}

static bool settle_transfer(HANDLE port, uint64_t token, DWORD *returned) {
    BOOL success = GetOverlappedResult(port, &transfer_operation, returned, FALSE);
    DWORD error = success ? ERROR_SUCCESS : GetLastError();
    enum mvo_vioser_transfer_result result = mvo_vioser_transfer_observe(&transfer, token, success != FALSE, error,
        transfer_native_pending && HasOverlappedIoCompleted(&transfer_operation), *returned, transfer.direction == MVO_VIOSER_TRANSFER_READ ? transfer_buffer : NULL);
    return result != 0;
}
static void retain_transfer(HANDLE port, uint64_t token, DWORD *returned) {
    MARK("mvo.vioser-transfer status=retained-pending-failure");
    while (!settle_transfer(port, token, returned)) {
        if (!ResetEvent(transfer_operation.hEvent)) Sleep(INFINITE);
        if (settle_transfer(port, token, returned)) break;
        if (WaitForSingleObject(transfer_operation.hEvent, INFINITE) != WAIT_OBJECT_0) Sleep(INFINITE);
    }
}
static bool transfer_once(HANDLE port, ULONGLONG began) {
    bool expired = GetTickCount64() - began >= 15000u;
    bool stopped_before = WaitForSingleObject(cancel_event, 0) == WAIT_OBJECT_0;
    if (expired || stopped_before) {
        mvo_vioser_transfer_request_cancel(&transfer, expired, stopped_before);
        return false;
    }
    enum mvo_vioser_transfer_direction direction = mvo_vioser_transfer_next_phase(&transfer);
    size_t remaining = mvo_vioser_transfer_remaining(&transfer);
    size_t requested = remaining < 7u ? remaining : 7u; /* deliberate bounded fragments */
    uint64_t token = 0;
    if (!mvo_vioser_transfer_begin(&transfer, direction, requested, &token)) return false;
    memset(&transfer_operation, 0, sizeof(transfer_operation));
    memset(transfer_buffer, 0, sizeof(transfer_buffer));
    transfer_operation.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (transfer_operation.hEvent == NULL) {
        /* No native I/O was submitted; terminal rejection still uses the token. */
        (void)mvo_vioser_transfer_observe(&transfer, token, false, ERROR_NOT_ENOUGH_MEMORY, true, 0, NULL);
        return false;
    }
    expired = GetTickCount64() - began >= 15000u;
    stopped_before = WaitForSingleObject(cancel_event, 0) == WAIT_OBJECT_0;
    if (expired || stopped_before) {
        mvo_vioser_transfer_request_cancel(&transfer, expired, stopped_before);
        /* No native request exists; reject this reserved token before release. */
        (void)mvo_vioser_transfer_observe(&transfer, token, false, ERROR_OPERATION_ABORTED, true, 0, NULL);
        (void)CloseHandle(transfer_operation.hEvent);
        transfer_operation.hEvent = NULL;
        return false;
    }
    if (direction == MVO_VIOSER_TRANSFER_WRITE) memcpy(transfer_buffer,
        MVO_VIOSER_PROBE_REPLY + transfer.write_offset, requested);
    DWORD returned = 0;
    BOOL issued = direction == MVO_VIOSER_TRANSFER_READ
        ? ReadFile(port, transfer_buffer, (DWORD)requested, NULL, &transfer_operation)
        : WriteFile(port, transfer_buffer, (DWORD)requested, NULL, &transfer_operation);
    DWORD initial_error = issued ? ERROR_SUCCESS : GetLastError();
    transfer_native_pending = !issued && initial_error == ERROR_IO_PENDING;
    if (issued) {
        BOOL obtained = GetOverlappedResult(port, &transfer_operation, &returned, FALSE);
        DWORD actual_error = obtained ? ERROR_SUCCESS : GetLastError();
        (void)mvo_vioser_transfer_observe(&transfer, token, obtained != FALSE, actual_error, true, returned, direction == MVO_VIOSER_TRANSFER_READ ? transfer_buffer : NULL);
    } else if (!transfer_native_pending) {
        (void)mvo_vioser_transfer_observe(&transfer, token, false, initial_error, true, 0, NULL);
    }
    HANDLE events[2] = {transfer_operation.hEvent, cancel_event};
    while (!mvo_vioser_transfer_can_release(&transfer)) {
        ULONGLONG elapsed = GetTickCount64() - began;
        bool stopped = WaitForSingleObject(cancel_event, 0) == WAIT_OBJECT_0;
        if (elapsed >= 15000u || stopped) mvo_vioser_transfer_request_cancel(&transfer, elapsed >= 15000u, stopped);
        if (settle_transfer(port, token, &returned)) break;
        DWORD remaining_time = elapsed < 15000u ? (DWORD)(15000u - elapsed) : 0u;
        DWORD wait = stopped ? WAIT_OBJECT_0 + 1u : WaitForMultipleObjects(2, events, FALSE, remaining_time);
        if (wait == WAIT_OBJECT_0) {
            bool late = GetTickCount64() - began >= 15000u;
            bool interrupted = WaitForSingleObject(cancel_event, 0) == WAIT_OBJECT_0;
            if (late || interrupted) mvo_vioser_transfer_request_cancel(&transfer, late, interrupted);
            if (settle_transfer(port, token, &returned)) break;
        }
        bool user = wait == WAIT_OBJECT_0 + 1u;
        mvo_vioser_transfer_request_cancel(&transfer, !user, user);
        BOOL cancelled = CancelIoEx(port, &transfer_operation);
        mvo_vioser_transfer_cancel_result(&transfer, cancelled ? 1u : GetLastError() == ERROR_NOT_FOUND ? 2u : 3u);
        if (!settle_transfer(port, token, &returned)) {
            (void)WaitForSingleObject(transfer_operation.hEvent, 2000u);
            if (!settle_transfer(port, token, &returned)) retain_transfer(port, token, &returned);
        }
        break;
    }
    if (!mvo_vioser_transfer_can_release(&transfer)) retain_transfer(port, token, &returned);
    bool closed = CloseHandle(transfer_operation.hEvent) != FALSE;
    transfer_operation.hEvent = NULL;
    return closed && !transfer.failed;
}

__declspec(noreturn) void mvo_start(void) {
    mvo_vioser_op_init(&ownership);
    mvo_vioser_transfer_init(&transfer);
    cancel_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (cancel_event == NULL || !SetConsoleCtrlHandler(control, TRUE)) {
        MARK("mvo.vioser-transfer status=control-unavailable"); ExitProcess(10);
    }
    if (!discover()) { MARK("mvo.vioser-transfer status=discovery-failed"); ExitProcess(11); }
    HANDLE port = CreateFileW(selected_path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
    if (port == INVALID_HANDLE_VALUE) { MARK("mvo.vioser-transfer status=open-failed"); ExitProcess(12); }
    DWORD returned = 0;
    mvo_vioser_info information;
    bool verified = query(port, GetTickCount64(), &returned)
        && mvo_vioser_parse_info(info_buffer, returned, intended_name, sizeof(intended_name)-1u, false, &information) == MVO_VIOSER_MATCH
        && information.id == selected_id && information.host_connected && information.guest_connected;
    bool passed = verified;
    ULONGLONG began = GetTickCount64();
    bool write_verified = false;
    while (passed && !mvo_vioser_transfer_success(&transfer)) {
        if (GetTickCount64() - began >= 15000u || WaitForSingleObject(cancel_event, 0) == WAIT_OBJECT_0) { passed = false; break; }
        if (!write_verified && mvo_vioser_transfer_next_phase(&transfer) == MVO_VIOSER_TRANSFER_WRITE) {
            returned = 0;
            passed = query(port, GetTickCount64(), &returned)
                && mvo_vioser_parse_info(info_buffer, returned, intended_name, sizeof(intended_name)-1u, false, &information) == MVO_VIOSER_MATCH
                && information.id == selected_id && information.host_connected && information.guest_connected && !information.out_full;
            write_verified = passed;
        }
        if (passed) passed = transfer_once(port, began);
    }
    bool late = GetTickCount64() - began >= 15000u;
    bool interrupted = WaitForSingleObject(cancel_event, 0) == WAIT_OBJECT_0;
    if (late || interrupted) {
        mvo_vioser_transfer_request_cancel(&transfer, late, interrupted);
        passed = false;
    }
    if (!mvo_vioser_transfer_can_release(&transfer) || !mvo_vioser_op_can_release(&ownership)) Sleep(INFINITE);
    if (!CloseHandle(port)) passed = false;
    (void)SetConsoleCtrlHandler(control, FALSE);
    if (!passed || !mvo_vioser_transfer_success(&transfer)) { MARK("mvo.vioser-transfer status=failed"); ExitProcess(13); }
    MARK("mvo.vioser-transfer status=fixed-fixture-complete"); ExitProcess(0);
}
