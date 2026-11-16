// SPDX-License-Identifier: Apache-2.0
// Native ARM64 bootstrap: no shell, script engine, network or guest-agent dependency.
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <setupapi.h>
#include <cfgmgr32.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <powrprof.h>
#include "payload.h"
#include "storage_plan.h"

static HWND window, statusText, installButton, rows[3], storageOption, hibernationText, reclaimText, spaceText;
static HFONT font;
static WCHAR root[MAX_PATH], executable[MAX_PATH];
static HANDLE payloadHandles[64];
static BOOL busy, optimizeStorage;
static int scrollPosition, wheelRemainder;
static const UINT resultMessage = WM_APP + 1, completeMessage = WM_APP + 2, storageMessage = WM_APP + 3;
static const WCHAR graphicsKey[] = L"SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers";
static const WCHAR schedulerKey[] = L"SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers\\Scheduler";
typedef struct { BOOL present; DWORD value; } RegistryValue;

// Freestanding build uses only the Windows APIs; no external C runtime DLL.
void *memset(void *p, int value, size_t n) {
  unsigned char *b = p; while (n--) *b++ = (unsigned char)value; return p;
}
void *memcpy(void *to, const void *from, size_t n) {
  unsigned char *a = to; const unsigned char *b = from;
  while (n--) *a++ = *b++; return to;
}

static BOOL pathFor(WCHAR *out, const WCHAR *relative) {
  if (lstrlenW(root) + lstrlenW(relative) >= MAX_PATH) return FALSE;
  lstrcpyW(out, root); lstrcatW(out, relative); return TRUE;
}

static BOOL hashFile(HANDLE file, const unsigned char *expected, DWORD expectedSize) {
  BCRYPT_ALG_HANDLE algorithm = NULL; BCRYPT_HASH_HANDLE hash = NULL;
  unsigned char buffer[2048], digest[32]; DWORD read = 0, total = 0;
  BOOL ok = FALSE;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0) < 0) goto done;
  if (BCryptCreateHash(algorithm, &hash, NULL, 0, NULL, 0, 0) < 0) goto done;
  for (;;) {
    if (!ReadFile(file, buffer, sizeof(buffer), &read, NULL)) goto done;
    if (!read) break;
    if (read > expectedSize - total) goto done;
    total += read;
    if (BCryptHashData(hash, buffer, read, 0) < 0) goto done;
  }
  if (total != expectedSize || BCryptFinishHash(hash, digest, 32, 0) < 0) goto done;
  ok = TRUE;
  for (int i = 0; i < 32; i++) if (digest[i] != expected[i]) ok = FALSE;
done:
  if (hash) BCryptDestroyHash(hash);
  if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
  return ok;
}

static void releasePayload(void) {
  for (unsigned i = 0; i < PAYLOAD_COUNT; i++) {
    if (payloadHandles[i] && payloadHandles[i] != INVALID_HANDLE_VALUE) CloseHandle(payloadHandles[i]);
    payloadHandles[i] = NULL;
  }
}

static BOOL verifyPayload(void) {
  // Retain deny-write/delete handles until Windows has processed all packages.
  for (unsigned i = 0; i < PAYLOAD_COUNT; i++) {
    WCHAR path[MAX_PATH]; BY_HANDLE_FILE_INFORMATION info;
    if (!pathFor(path, payload[i].path)) return FALSE;
    HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                          FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    payloadHandles[i] = f;
    if (f == INVALID_HANDLE_VALUE || !GetFileInformationByHandle(f, &info)
        || (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))
        || info.nFileSizeHigh || info.nFileSizeLow != payload[i].size
        || !hashFile(f, payload[i].sha, payload[i].size)) return FALSE;
  }
  return TRUE;
}

static BOOL prefix(const WCHAR *value, const WCHAR *pattern) {
  int n = lstrlenW(pattern);
  return lstrlenW(value) >= n && CompareStringOrdinal(value, n, pattern, n, TRUE) == CSTR_EQUAL
    && (value[n] == L'&' || value[n] == 0);
}

// -1 means enumeration failed, 0 absent, 1 driver needed, 2 all matching devices healthy.
static int deviceState(unsigned package) {
  HDEVINFO set = SetupDiGetClassDevsW(NULL, L"PCI", NULL, DIGCF_ALLCLASSES | DIGCF_PRESENT);
  if (set == INVALID_HANDLE_VALUE) return -1;
  int found = 0; BOOL healthy = TRUE, failed = FALSE;
  for (DWORD i = 0;; i++) {
    SP_DEVINFO_DATA device; memset(&device, 0, sizeof(device)); device.cbSize = sizeof(device);
    if (!SetupDiEnumDeviceInfo(set, i, &device)) {
      if (GetLastError() != ERROR_NO_MORE_ITEMS) failed = TRUE;
      break;
    }
    WCHAR ids[1024]; DWORD type = 0, required = 0;
    memset(ids, 0, sizeof(ids));
    if (!SetupDiGetDeviceRegistryPropertyW(set, &device, SPDRP_HARDWAREID, &type,
                                          (BYTE *)ids, sizeof(ids) - 4, &required)) {
      if (GetLastError() != ERROR_INVALID_DATA) failed = TRUE;
      continue;
    }
    if (type != REG_MULTI_SZ || required > sizeof(ids) - 4) { failed = TRUE; continue; }
    BOOL matches = FALSE;
    for (WCHAR *id = ids; *id; id += lstrlenW(id) + 1) {
      if (prefix(id, packages[package].id1) || prefix(id, packages[package].id2)) matches = TRUE;
    }
    if (!matches) continue;
    found++;
    ULONG status = 0, problem = 0; WCHAR service[128];
    memset(service, 0, sizeof(service));
    if (CM_Get_DevNode_Status(&status, &problem, device.DevInst, 0) != CR_SUCCESS
        || problem || !(status & DN_STARTED)
        || !SetupDiGetDeviceRegistryPropertyW(set, &device, SPDRP_SERVICE, &type,
                                             (BYTE *)service, sizeof(service) - 2, NULL)
        || type != REG_SZ || lstrcmpiW(service, packages[package].service)) healthy = FALSE;
  }
  SetupDiDestroyDeviceInfoList(set);
  return failed ? -1 : !found ? 0 : healthy ? 2 : 1;
}

static BOOL readSetting(const WCHAR *key, const WCHAR *name, RegistryValue *value) {
  HKEY handle = NULL; value->present = FALSE; value->value = 0;
  LSTATUS result = RegOpenKeyExW(HKEY_LOCAL_MACHINE, key, 0, KEY_READ, &handle);
  if (result == ERROR_FILE_NOT_FOUND) return TRUE;
  if (result != ERROR_SUCCESS) return FALSE;
  DWORD size = sizeof(DWORD), type = 0;
  result = RegQueryValueExW(handle, name, NULL, &type, (BYTE *)&value->value, &size);
  RegCloseKey(handle);
  if (result == ERROR_FILE_NOT_FOUND) { value->value = 0; return TRUE; }
  if (result != ERROR_SUCCESS || type != REG_DWORD || size != sizeof(DWORD)) return FALSE;
  value->present = TRUE; return TRUE;
}

static BOOL restoreSetting(const WCHAR *key, const WCHAR *name, RegistryValue value) {
  HKEY handle = NULL; RegistryValue after;
  LSTATUS result = RegOpenKeyExW(HKEY_LOCAL_MACHINE, key, 0, KEY_SET_VALUE, &handle);
  if (result == ERROR_FILE_NOT_FOUND && !value.present) return TRUE;
  if (result != ERROR_SUCCESS) return FALSE;
  result = value.present ? RegSetValueExW(handle, name, 0, REG_DWORD, (BYTE *)&value.value, 4)
                        : RegDeleteValueW(handle, name);
  RegCloseKey(handle);
  if (result != ERROR_SUCCESS && !(result == ERROR_FILE_NOT_FOUND && !value.present)) return FALSE;
  return readSetting(key, name, &after) && after.present == value.present && after.value == value.value;
}

static BOOL recordSettings(RegistryValue a, RegistryValue b) {
  // Store only these two non-secret settings in an administrator-owned directory.
  WCHAR path[MAX_PATH], file[MAX_PATH], text[256]; DWORD wrote = 0;
  if (!GetEnvironmentVariableW(L"ProgramFiles", path, MAX_PATH)
      || lstrlenW(path) > MAX_PATH - 60) return FALSE;
  lstrcatW(path, L"\\macOpenVM Guest Tools");
  if (!CreateDirectoryW(path, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return FALSE;
  DWORD attributes = GetFileAttributesW(path);
  if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return FALSE;
  if (!GetTempFileNameW(path, L"gpu", 0, file)) return FALSE;
  HANDLE out = CreateFileW(file, GENERIC_WRITE, 0, NULL, TRUNCATE_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (out == INVALID_HANDLE_VALUE) return FALSE;
  int count = wsprintfW(text, L"macOpenVM graphics recovery settings (UTF-16LE)\r\nEnablePreemption present=%u value=%u\r\nTdrDebugMode present=%u value=%u\r\n",
                        a.present, a.value, b.present, b.value);
  BOOL ok = WriteFile(out, text, (DWORD)count * 2, &wrote, NULL) && wrote == (DWORD)count * 2
    && FlushFileBuffers(out);
  CloseHandle(out); return ok;
}

static DWORD installPackage(unsigned package) {
  WCHAR system[MAX_PATH], inf[MAX_PATH], command[768]; STARTUPINFOW startup;
  PROCESS_INFORMATION process; memset(&startup, 0, sizeof(startup)); startup.cb = sizeof(startup);
  memset(&process, 0, sizeof(process));
  UINT length = GetSystemDirectoryW(system, MAX_PATH);
  if (!length || length > MAX_PATH - 20 || !pathFor(inf, packages[package].inf)) return ERROR_BAD_PATHNAME;
  lstrcatW(system, L"\\pnputil.exe");
  wsprintfW(command, L"\"%s\" /add-driver \"%s\" /install", system, inf);
  if (!CreateProcessW(system, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, root, &startup, &process))
    return GetLastError();
  CloseHandle(process.hThread);
  DWORD result = ERROR_GEN_FAILURE;
  if (WaitForSingleObject(process.hProcess, INFINITE) == WAIT_OBJECT_0) GetExitCodeProcess(process.hProcess, &result);
  CloseHandle(process.hProcess); return result;
}

typedef struct { WCHAR volume[MAX_PATH]; } StorageContext;

static int windowsVolume(void *context) {
  StorageContext *storage = context; WCHAR path[MAX_PATH];
  UINT length = GetWindowsDirectoryW(path, MAX_PATH);
  if (!length || length >= MAX_PATH || !GetVolumePathNameW(path, storage->volume, MAX_PATH)) return 0;
  // Support the ordinary local Windows drive. Refuse mount points/UNC paths
  // rather than constructing command arguments from arbitrary path text.
  return lstrlenW(storage->volume) == 3 && storage->volume[0] >= L'A' && storage->volume[0] <= L'Z'
    && storage->volume[1] == L':' && storage->volume[2] == L'\\';
}

static unsigned long storageCommand(void *context, enum MVOStorageStep step) {
  StorageContext *storage = context;
  WCHAR program[MAX_PATH], command[512]; STARTUPINFOW startup; PROCESS_INFORMATION process;
  memset(&startup, 0, sizeof(startup)); startup.cb = sizeof(startup); memset(&process, 0, sizeof(process));
  UINT length = GetSystemDirectoryW(program, MAX_PATH);
  if (!length || length > MAX_PATH - 20) return ERROR_BAD_PATHNAME;
  if (step == MVO_DISABLE_HIBERNATION) {
    lstrcatW(program, L"\\powercfg.exe");
    wsprintfW(command, L"\"%s\" /hibernate off", program);
  } else if (step == MVO_RETRIM) {
    lstrcatW(program, L"\\defrag.exe");
    wsprintfW(command, L"\"%s\" %c: /L", program, storage->volume[0]);
  } else return ERROR_INVALID_PARAMETER;
  if (!CreateProcessW(program, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &process))
    return GetLastError();
  CloseHandle(process.hThread);
  DWORD result = ERROR_GEN_FAILURE;
  if (WaitForSingleObject(process.hProcess, INFINITE) == WAIT_OBJECT_0) GetExitCodeProcess(process.hProcess, &result);
  CloseHandle(process.hProcess); return result;
}

static int hibernationAbsent(void *context) {
  StorageContext *storage = context; SYSTEM_POWER_CAPABILITIES power; WCHAR path[MAX_PATH];
  memset(&power, 0, sizeof(power));
  if (!GetPwrCapabilities(&power) || power.HiberFilePresent) return 0;
  lstrcpyW(path, storage->volume); lstrcatW(path, L"hiberfil.sys");
  return GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES && GetLastError() == ERROR_FILE_NOT_FOUND;
}

static void showFreeSpace(void) {
  StorageContext storage; ULARGE_INTEGER available, total, freeBytes; WCHAR text[256];
  if (!windowsVolume(&storage) || !GetDiskFreeSpaceExW(storage.volume, &available, &total, &freeBytes)
      || !total.QuadPart || freeBytes.QuadPart > total.QuadPart) {
    SetWindowTextW(spaceText, L"Windows drive: space could not be checked. Open Storage settings."); return;
  }
  // Integer tenths of GiB; this is guest free space, not host allocation saved.
  ULONGLONG freeTenths = freeBytes.QuadPart / 1048576 * 10 / 1024;
  ULONGLONG totalTenths = total.QuadPart / 1048576 * 10 / 1024;
  wsprintfW(text, L"Windows drive %c: %lu.%lu GiB free of %lu.%lu GiB", storage.volume[0],
    (DWORD)(freeTenths / 10), (DWORD)(freeTenths % 10), (DWORD)(totalTenths / 10), (DWORD)(totalTenths % 10));
  SetWindowTextW(spaceText, text);
}

static DWORD WINAPI installAll(void *unused) {
  (void)unused; BOOL failures = FALSE, reboot = FALSE, missingGraphics = FALSE;
  if (!verifyPayload()) {
    releasePayload(); PostMessageW(window, completeMessage, 3, 0); return 0;
  }
  for (unsigned i = 0; i < PACKAGE_COUNT; i++) {
    int before = deviceState(i);
    if (before == 0) {
      if (packages[i].required) {
        missingGraphics = TRUE;
        PostMessageW(window, resultMessage, i, 8);
      } else PostMessageW(window, resultMessage, i, 1);
      continue;
    }
    if (before < 0) { failures = TRUE; PostMessageW(window, resultMessage, i, 5); continue; }
    RegistryValue preemption, tdr;
    if (packages[i].graphics && (!readSetting(schedulerKey, L"EnablePreemption", &preemption)
        || !readSetting(graphicsKey, L"TdrDebugMode", &tdr) || !recordSettings(preemption, tdr))) {
      failures = TRUE; PostMessageW(window, resultMessage, i, 6); continue;
    }
    PostMessageW(window, resultMessage, i, 2);
    DWORD result = installPackage(i);
    if (packages[i].graphics) {
      // Do both restorations even if one fails, including unsuccessful driver installs.
      BOOL a = restoreSetting(schedulerKey, L"EnablePreemption", preemption);
      BOOL b = restoreSetting(graphicsKey, L"TdrDebugMode", tdr);
      if (!a || !b) {
        releasePayload(); PostMessageW(window, resultMessage, i, 7);
        PostMessageW(window, completeMessage, 4, 0); return 0;
      }
    }
    if (result == ERROR_SUCCESS_REBOOT_REQUIRED) { reboot = TRUE; PostMessageW(window, resultMessage, i, 4); }
    else if ((result == ERROR_SUCCESS || result == ERROR_NO_MORE_ITEMS) && deviceState(i) == 2)
      PostMessageW(window, resultMessage, i, 3);
    else { failures = TRUE; PostMessageW(window, resultMessage, i, 5); }
  }
  releasePayload();
  StorageContext storage;
  MVOStorageOperations ops = { &storage, windowsVolume, storageCommand, hibernationAbsent };
  if (optimizeStorage) PostMessageW(window, storageMessage, 1, 0);
  MVOStorageResult storageResult = mvoOptimizeStorage(optimizeStorage, ops);
  PostMessageW(window, storageMessage, 0,
    (LPARAM)(storageResult.hibernation | (storageResult.reclaim << 8)));
  PostMessageW(window, completeMessage, missingGraphics ? 5 : failures ? 2 : reboot ? 1 : 0, 0);
  return 0;
}

static BOOL elevated(void) {
  HANDLE token = NULL; TOKEN_ELEVATION info; DWORD size = 0;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return FALSE;
  BOOL ok = GetTokenInformation(token, TokenElevation, &info, sizeof(info), &size) && info.TokenIsElevated;
  CloseHandle(token); return ok;
}

static HWND control(const WCHAR *kind, const WCHAR *label, DWORD style, int x, int y, int w, int h, int id) {
  HWND result = CreateWindowExW(0, kind, label, WS_CHILD | WS_VISIBLE | style,
                                x, y, w, h, window, (HMENU)(INT_PTR)id, GetModuleHandleW(NULL), NULL);
  SendMessageW(result, WM_SETFONT, (WPARAM)font, TRUE); return result;
}

static void scrollTo(HWND hwnd, int position) {
  SCROLLINFO info; memset(&info, 0, sizeof(info));
  info.cbSize = sizeof(info); info.fMask = SIF_POS; info.nPos = position;
  int next = SetScrollInfo(hwnd, SB_VERT, &info, TRUE);
  if (next != scrollPosition) {
    ScrollWindowEx(hwnd, 0, scrollPosition - next, NULL, NULL, NULL, NULL,
                   SW_SCROLLCHILDREN | SW_INVALIDATE | SW_ERASE);
    scrollPosition = next;
  }
}

static void revealFocus(void) {
  HWND focused = GetFocus(); RECT child, client;
  if (!focused || GetParent(focused) != window || !GetWindowRect(focused, &child)
      || !GetClientRect(window, &client)) return;
  MapWindowPoints(NULL, window, (POINT *)&child, 2);
  if (child.top < 0) scrollTo(window, scrollPosition + child.top - 8);
  else if (child.bottom > client.bottom) scrollTo(window, scrollPosition + child.bottom - client.bottom + 8);
}

static LRESULT CALLBACK windowProc(HWND hwnd, UINT message, WPARAM w, LPARAM l) {
  if (message == WM_SIZE) {
    RECT client; GetClientRect(hwnd, &client);
    SCROLLINFO info; memset(&info, 0, sizeof(info)); info.cbSize = sizeof(info);
    info.fMask = SIF_RANGE | SIF_PAGE; info.nMax = 599; info.nPage = (UINT)client.bottom;
    SetScrollInfo(hwnd, SB_VERT, &info, TRUE);
    return 0;
  }
  if (message == WM_VSCROLL) {
    SCROLLINFO info; memset(&info, 0, sizeof(info)); info.cbSize = sizeof(info); info.fMask = SIF_ALL;
    GetScrollInfo(hwnd, SB_VERT, &info); int next = scrollPosition;
    switch (LOWORD(w)) {
      case SB_LINEUP: next -= 28; break;
      case SB_LINEDOWN: next += 28; break;
      case SB_PAGEUP: next -= (int)info.nPage; break;
      case SB_PAGEDOWN: next += (int)info.nPage; break;
      case SB_THUMBTRACK: case SB_THUMBPOSITION: next = info.nTrackPos; break;
      case SB_TOP: next = info.nMin; break;
      case SB_BOTTOM: next = info.nMax; break;
      default: return 0;
    }
    scrollTo(hwnd, next); return 0;
  }
  if (message == WM_MOUSEWHEEL) {
    wheelRemainder += (short)HIWORD(w);
    scrollTo(hwnd, scrollPosition - (wheelRemainder / WHEEL_DELTA) * 48);
    wheelRemainder %= WHEEL_DELTA; return 0;
  }
  if (message == WM_COMMAND && LOWORD(w) == 1 && !busy) {
    optimizeStorage = SendMessageW(storageOption, BM_GETCHECK, 0, 0) == BST_CHECKED;
    if (!elevated()) {
      SHELLEXECUTEINFOW launch; memset(&launch, 0, sizeof(launch)); launch.cbSize = sizeof(launch);
      launch.hwnd = hwnd; launch.lpVerb = L"runas"; launch.lpFile = executable;
      launch.lpParameters = optimizeStorage ? L"--install --storage" : L"--install"; launch.nShow = SW_SHOWNORMAL;
      if (ShellExecuteExW(&launch)) DestroyWindow(hwnd);
      else SetWindowTextW(statusText, L"Installation was not started. Choose Install when you are ready to approve Windows' administrator prompt.");
    } else {
      busy = TRUE; EnableWindow(installButton, FALSE); EnableWindow(storageOption, FALSE);
      SetWindowTextW(hibernationText, optimizeStorage ? L"Hibernation: waiting for driver setup" : L"Hibernation: left unchanged");
      SetWindowTextW(reclaimText, optimizeStorage ? L"Unused disk blocks: waiting" : L"Unused disk blocks: reclaim not requested");
      SetWindowTextW(statusText, L"Checking the complete driver package. Please keep this window open.");
      HANDLE worker = CreateThread(NULL, 0, installAll, NULL, 0, NULL);
      if (worker) CloseHandle(worker);
      else { busy = FALSE; EnableWindow(installButton, TRUE); EnableWindow(storageOption, TRUE); SetWindowTextW(statusText, L"Could not start installation. Try again."); }
    }
    return 0;
  }
  if (message == WM_COMMAND && LOWORD(w) == 2) {
    SHELLEXECUTEINFOW launch; memset(&launch, 0, sizeof(launch)); launch.cbSize = sizeof(launch);
    launch.hwnd = hwnd; launch.lpFile = L"ms-settings:storagesense"; launch.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&launch)) SetWindowTextW(statusText, L"Open Windows Settings > System > Storage to review disk usage.");
    return 0;
  }
  if (message == storageMessage) {
    if (w == 1) {
      SetWindowTextW(hibernationText, L"Hibernation: applying space-saving setting...");
      SetWindowTextW(reclaimText, L"Unused disk blocks: reclaiming; this can take a few minutes...");
    } else {
      int h = (int)(l & 255), r = (int)((l >> 8) & 255);
      SetWindowTextW(hibernationText, h == MVO_STORAGE_SKIPPED ? L"Hibernation: left unchanged"
        : h == MVO_STORAGE_READY ? L"Hibernation: off; no hibernation file"
        : L"Hibernation: could not confirm the change. Retry Install / Repair.");
      SetWindowTextW(reclaimText, r == MVO_STORAGE_SKIPPED ? L"Unused disk blocks: reclaim not requested"
        : r == MVO_STORAGE_READY ? L"Unused disk blocks: Windows reclaim completed"
        : L"Unused disk blocks: reclaim unavailable or failed. Retry later.");
      showFreeSpace();
    }
    return 0;
  }
  if (message == resultMessage && w < PACKAGE_COUNT) {
    const WCHAR *states[] = {L"Ready", L"Device is not attached", L"Installing...", L"Working",
      L"Restart required", L"Needs attention - check Windows Device Manager", L"Could not preserve graphics settings",
      L"Graphics settings restoration failed", L"Not detected - setup is incomplete"};
    if (l >= 0 && l < 9) { WCHAR text[256]; wsprintfW(text, L"%s: %s", packages[w].name, states[l]); SetWindowTextW(rows[w], text); }
    return 0;
  }
  if (message == completeMessage) {
    const WCHAR *messages[] = {
      L"Your matching drivers are ready. Review the storage results above before closing.",
      L"Installation finished. Save your work, then restart Windows to finish setting up the drivers.",
      L"Some devices need attention. Open Windows Device Manager for details, or choose Install to retry. Other drivers were processed.",
      L"The tools disc is incomplete or changed. No drivers were installed. Prepare Guest Tools again in macOpenVM.",
      L"Graphics recovery settings could not be restored. Do not restart yet. The original values are in Program Files > macOpenVM Guest Tools.",
      L"Graphics setup is incomplete: Windows cannot see the selected GPU. Choose Restart in Windows, then run Install again. If it is still missing, check Graphics Settings in macOpenVM."
    };
    busy = FALSE; EnableWindow(installButton, w != 4); EnableWindow(storageOption, w != 4);
    if (w == 3 || w == 4) {
      SetWindowTextW(hibernationText, L"Hibernation: storage setup was not started");
      SetWindowTextW(reclaimText, L"Unused disk blocks: reclaim was not started");
    }
    SetWindowTextW(installButton, L"Install / Repair");
    if (w < 6) SetWindowTextW(statusText, messages[w]);
    return 0;
  }
  if (message == WM_CLOSE && busy) {
    MessageBoxW(hwnd, L"Windows setup is still running. Please wait until it finishes.", L"macOpenVM Guest Tools", MB_OK | MB_ICONINFORMATION);
    return 0;
  }
  if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
  return DefWindowProcW(hwnd, message, w, l);
}

void mvo_start(void) {
  DWORD length = GetModuleFileNameW(NULL, executable, MAX_PATH);
  if (!length || length >= MAX_PATH || length > 210) ExitProcess(1);
  lstrcpyW(root, executable);
  int last = -1; for (DWORD i = 0; i < length; i++) if (root[i] == L'\\') last = (int)i;
  if (last < 0) ExitProcess(1); root[last + 1] = 0;
  WNDCLASSW cls; memset(&cls, 0, sizeof(cls)); cls.lpfnWndProc = windowProc;
  cls.hInstance = GetModuleHandleW(NULL); cls.lpszClassName = L"MacOpenVMGuestTools";
  cls.hCursor = LoadCursorW(NULL, IDC_ARROW); cls.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
  if (!RegisterClassW(&cls)) ExitProcess(1);
  // System DPI scaling handles the whole form consistently on high-DPI desktops.
  font = CreateFontW(-16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                     OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  // Respect the taskbar and scaled desktop; shorter displays scroll the form.
  RECT work = { 0, 0, 800, 600 };
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  int height = work.bottom - work.top - 16; if (height > 640) height = 640;
  if (height < 200) height = 200;
  int x = work.left + (work.right - work.left - 680) / 2;
  if (x < work.left) x = work.left;
  window = CreateWindowExW(WS_EX_CONTROLPARENT, cls.lpszClassName, L"macOpenVM Guest Tools",
    WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_VSCROLL,
    x, work.top + 8, 680, height, NULL, NULL, cls.hInstance, NULL);
  if (!window) ExitProcess(1);
  control(L"STATIC", L"Make Windows work with your Mac", 0, 28, 24, 570, 32, 0);
  control(L"STATIC", L"Install all compatible drivers together. Windows will ask for administrator permission. Your VM will not restart automatically.", 0, 28, 66, 570, 56, 0);
  for (unsigned i = 0; i < PACKAGE_COUNT; i++) {
    WCHAR label[128]; wsprintfW(label, L"%s: Ready to check", packages[i].name);
    rows[i] = control(L"STATIC", label, 0, 28, 128 + (int)i * 32, 600, 30, 0);
  }
  storageOption = control(L"BUTTON", L"Save disk space (recommended)", WS_TABSTOP | BS_AUTOCHECKBOX, 28, 236, 600, 28, 3);
  SendMessageW(storageOption, BM_SETCHECK, BST_CHECKED, 0);
  control(L"STATIC", L"Turn off Windows hibernation and Fast Startup, then reclaim unused disk blocks. Paging, recovery and your files stay available. No compression is added. Uncheck to keep your settings.", 0, 28, 270, 600, 64, 0);
  hibernationText = control(L"STATIC", L"Hibernation: ready to check", 0, 28, 342, 600, 30, 0);
  reclaimText = control(L"STATIC", L"Unused disk blocks: ready to reclaim", 0, 28, 376, 600, 40, 0);
  spaceText = control(L"STATIC", L"", 0, 28, 418, 600, 30, 0);
  statusText = control(L"STATIC", L"Choose Install to set up matching drivers and the selected storage option. Your VM will not restart automatically.", 0, 28, 456, 600, 68, 0);
  control(L"BUTTON", L"Storage settings", WS_TABSTOP, 28, 548, 180, 36, 2);
  installButton = control(L"BUTTON", L"Install", WS_TABSTOP | BS_DEFPUSHBUTTON, 450, 548, 178, 36, 1);
  showFreeSpace();
  ShowWindow(window, SW_SHOWNORMAL); UpdateWindow(window); SetFocus(storageOption);
  int count = 0; LPWSTR *args = CommandLineToArgvW(GetCommandLineW(), &count);
  BOOL installArgs = args && (count == 2 || (count == 3 && !lstrcmpW(args[2], L"--storage")))
    && !lstrcmpW(args[1], L"--install");
  if (installArgs) SendMessageW(storageOption, BM_SETCHECK, count == 3 ? BST_CHECKED : BST_UNCHECKED, 0);
  BOOL autoInstall = installArgs && elevated();
  if (args) LocalFree(args);
  if (autoInstall) PostMessageW(window, WM_COMMAND, 1, 0);
  MSG message;
  while (GetMessageW(&message, NULL, 0, 0) > 0) {
    if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    else revealFocus();
  }
  if (font) DeleteObject(font);
  ExitProcess(0);
}
