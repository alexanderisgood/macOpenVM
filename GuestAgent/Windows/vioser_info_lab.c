/* SPDX-License-Identifier: Apache-2.0 */
/* Original experimental discovery/INFO diagnostic. No raw port bytes, TLS or service. */
#include "vioser_win32_lab.h"

__declspec(noreturn) void mvo_start(void) {
    mvo_vioser_op_init(&ownership);
    cancel_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (cancel_event == NULL || !SetConsoleCtrlHandler(control, TRUE)) {
        MARK("mvo.vioser-info status=control-unavailable"); ExitProcess(10);
    }
    HDEVINFO devices = SetupDiGetClassDevsW(&port_guid, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (devices == INVALID_HANDLE_VALUE) { MARK("mvo.vioser-info status=discovery-unavailable"); ExitProcess(11); }
    mvo_vioser_scan scan = {0};
    ULONGLONG began = GetTickCount64();
    /* This bounds admitted IOCTL waits, not synchronous SetupAPI call duration. */
    bool ended = false;
    for (DWORD index = 0; index <= 32u; ++index) {
        SP_DEVICE_INTERFACE_DATA data;
        memset(&data, 0, sizeof(data)); data.cbSize = sizeof(data);
        if (!SetupDiEnumDeviceInterfaces(devices, NULL, &port_guid, index, &data)) {
            ended = GetLastError() == ERROR_NO_MORE_ITEMS;
            if (!ended) scan.failed = true;
            break;
        }
        /* Index32 is the boundary check only; no33rd handle or IOCTL is admitted. */
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
        if (length == 0u || length == units) { scan.failed = true; break; }
        /* Metadata-only FILE_ANY_ACCESS IOCTL. Opening may change GuestConnected. */
        HANDLE port = CreateFileW(detail->DevicePath, 0, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
        if (port == INVALID_HANDLE_VALUE) { scan.failed = true; break; }
        DWORD returned = 0;
        bool valid = query(port, began, &returned);
        mvo_vioser_info information;
        enum mvo_vioser_parse_result parsed = valid ? mvo_vioser_parse_info(info_buffer, returned,
            intended_name, sizeof(intended_name) - 1u, false, &information) : MVO_VIOSER_INVALID;
        /* The pinned producer copies BOOLEAN bytes without canonicalizing them. */
        bool released = mvo_vioser_op_can_release(&ownership) && CloseHandle(port);
        if (!released || !mvo_vioser_scan_record(&scan, parsed)) { scan.failed = true; break; }
    }
    if (!SetupDiDestroyDeviceInfoList(devices)) scan.failed = true;
    /* The control event remains valid for concurrent handlers until process teardown. */
    (void)SetConsoleCtrlHandler(control, FALSE);
    if (!mvo_vioser_op_can_release(&ownership)) { Sleep(INFINITE); }
    if (!ended || scan.failed) { MARK("mvo.vioser-info status=failed"); ExitProcess(12); }
    if (!mvo_vioser_scan_unique(&scan)) { MARK("mvo.vioser-info status=no-exact-port"); ExitProcess(13); }
    MARK("mvo.vioser-info status=unique-metadata-match");
    ExitProcess(0);
}
