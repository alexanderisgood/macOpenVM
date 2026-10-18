// SPDX-License-Identifier: Apache-2.0
// Original diskless firmware shutdown probe. Not a Windows ACPI/OS shutdown test.
#include <Uefi.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>
#include <Library/UefiLib.h>

#define STARTUP_WAIT_100NS  300000000ULL

EFI_STATUS
EFIAPI
UefiMain (EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
{
  EFI_EVENT Timer = NULL;
  EFI_STATUS Status;
  EFI_STATUS CloseStatus;
  UINTN Index = 1;

  (VOID)ImageHandle;
  (VOID)SystemTable;
  Status = gBS->CreateEvent (EVT_TIMER, TPL_APPLICATION, NULL, NULL, &Timer);
  if (EFI_ERROR (Status)) {
    Print (L"mvo.shutdown-probe.failure=create-timer\n");
    return Status;
  }
  Status = gBS->SetTimer (Timer, TimerRelative, STARTUP_WAIT_100NS);
  if (EFI_ERROR (Status)) {
    gBS->CloseEvent (Timer);
    Print (L"mvo.shutdown-probe.failure=set-timer\n");
    return Status;
  }
  Print (L"mvo.shutdown-probe.ready version=1 wait-seconds=30\n");
  Status = gBS->WaitForEvent (1, &Timer, &Index);
  CloseStatus = gBS->CloseEvent (Timer);
  if (EFI_ERROR (Status) || Index != 0) {
    Print (L"mvo.shutdown-probe.failure=wait-timer\n");
    return EFI_DEVICE_ERROR;
  }
  if (EFI_ERROR (CloseStatus)) {
    Print (L"mvo.shutdown-probe.failure=close-timer\n");
    return CloseStatus;
  }
  Print (L"mvo.shutdown-probe.request reset=shutdown\n");
  gRT->ResetSystem (EfiResetShutdown, EFI_SUCCESS, 0, NULL);
  Print (L"mvo.shutdown-probe.failure=reset-returned\n");
  return EFI_DEVICE_ERROR;
}
