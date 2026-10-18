// SPDX-License-Identifier: Apache-2.0
// Original no-OS keyboard observer. No disks, variables, TPM or input injection.
#include <Uefi.h>
#include <Protocol/SimpleTextInEx.h>
#include <Library/UefiLib.h>
#include <Library/UefiBootServicesTableLib.h>

#define KEY_COUNT 24
#define KEY_TIMEOUT (15ULL * 10000000ULL)

STATIC EFI_STATUS
ReadKey (EFI_SIMPLE_TEXT_INPUT_EX_PROTOCOL *Input, EFI_KEY_DATA *Key)
{
  EFI_EVENT Deadline = NULL;
  EFI_EVENT Events[2];
  UINTN Index;
  EFI_STATUS Status;

  Status = gBS->CreateEvent (EVT_TIMER, TPL_APPLICATION, NULL, NULL, &Deadline);
  if (EFI_ERROR (Status)) {
    return Status;
  }
  Status = gBS->SetTimer (Deadline, TimerRelative, KEY_TIMEOUT);
  if (!EFI_ERROR (Status)) {
    Events[0] = Input->WaitForKeyEx;
    Events[1] = Deadline;
    for (;;) {
      Status = gBS->CheckEvent (Deadline);
      if (Status == EFI_SUCCESS) {
        Status = EFI_TIMEOUT;
        break;
      }
      if (Status != EFI_NOT_READY) {
        break;
      }
      Status = Input->ReadKeyStrokeEx (Input, Key);
      if (Status != EFI_NOT_READY) {
        break;
      }
      Status = gBS->WaitForEvent (2, Events, &Index);
      if (EFI_ERROR (Status)) {
        break;
      }
      if (Index == 1) {
        Status = EFI_TIMEOUT;
        break;
      }
      if (Index != 0) {
        Status = EFI_COMPROMISED_DATA;
        break;
      }
    }
  }
  gBS->SetTimer (Deadline, TimerCancel, 0);
  gBS->CloseEvent (Deadline);
  return Status;
}

EFI_STATUS EFIAPI
UefiMain (EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
{
  EFI_SIMPLE_TEXT_INPUT_EX_PROTOCOL *Input = NULL;
  EFI_KEY_DATA Key;
  EFI_STATUS Status;
  EFI_EVENT Park = NULL;
  UINTN Index;
  UINTN EventIndex;

  Print (L"\nmvo.keyboard.begin version=1 count=%u\n", KEY_COUNT);
  Status = gBS->HandleProtocol (gST->ConsoleInHandle, &gEfiSimpleTextInputExProtocolGuid,
                                (VOID **)&Input);
  if (EFI_ERROR (Status) || Input == NULL || Input->WaitForKeyEx == NULL) {
    Print (L"mvo.keyboard.failure phase=protocol status=%r\n", Status);
    return EFI_UNSUPPORTED;
  }
  // Every row is an observation, never an automatic compatibility assertion.
  // The host independently checks the fixed scenario's actual returned values.
  for (Index = 0; Index < KEY_COUNT; Index++) {
    Print (L"mvo.keyboard.ready index=%u\n", Index);
    Status = ReadKey (Input, &Key);
    if (EFI_ERROR (Status)) {
      Print (L"mvo.keyboard.failure phase=input index=%u status=%r\n", Index, Status);
      return Status;
    }
    Print (L"mvo.keyboard.observed index=%u unicode=%u scan=%u shift=%08x toggle=%02x\n",
           Index, Key.Key.UnicodeChar, Key.Key.ScanCode, Key.KeyState.KeyShiftState,
           Key.KeyState.KeyToggleState);
  }
  Print (L"mvo.keyboard.complete count=%u\n", KEY_COUNT);
  // Sleep on an event while the owning host records observations and stops only
  // this disposable fixture. Returning would accidentally target the EFI shell.
  Status = gBS->CreateEvent (0, TPL_APPLICATION, NULL, NULL, &Park);
  if (EFI_ERROR (Status)) {
    return Status;
  }
  for (;;) {
    Status = gBS->WaitForEvent (1, &Park, &EventIndex);
    if (EFI_ERROR (Status)) {
      gBS->CloseEvent (Park);
      return Status;
    }
  }
}
