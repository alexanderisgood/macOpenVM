// SPDX-License-Identifier: Apache-2.0
// Original positive trust-chain controller for a fresh, disposable no-OS lab.
#include <Uefi.h>
#include <Guid/GlobalVariable.h>
#include <Guid/ImageAuthentication.h>
#include <Guid/WinCertificate.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>
#include <Library/BaseMemoryLib.h>
#include <Library/DevicePathLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>
#include <Library/UefiLib.h>

#include "../PkEnrollmentProbe/FixtureCertificate.h"

#define AUTH_CAPACITY 8192U
#define ESL_SIZE      823U
#define TRUST_ATTRIBUTES (EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | \
                          EFI_VARIABLE_RUNTIME_ACCESS | EFI_VARIABLE_TIME_BASED_AUTHENTICATED_WRITE_ACCESS)

#include "BoundedInputs.h"

STATIC EFI_STATUS
ReadInputs (EFI_HANDLE ImageHandle, UINT8 Auth[3][AUTH_CAPACITY + 1], UINTN AuthSize[3],
            UINT8 Esl[ESL_SIZE + 1], EFI_HANDLE *DeviceHandle)
{
  EFI_LOADED_IMAGE_PROTOCOL *Image = NULL;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *FileSystem = NULL;
  EFI_FILE_PROTOCOL *Root = NULL;
  STATIC CHAR16 *Names[3] = { L"\\PK.AUTH", L"\\KEK.AUTH", L"\\DB.AUTH" };
  UINTN EslSize = 0;
  UINTN Index;
  EFI_STATUS Status;
  EFI_STATUS CloseStatus;

  *DeviceHandle = NULL;
  Status = gBS->HandleProtocol (ImageHandle, &gEfiLoadedImageProtocolGuid, (VOID **)&Image);
  if (EFI_ERROR (Status) || Image == NULL || Image->DeviceHandle == NULL) {
    return EFI_NOT_FOUND;
  }
  Status = gBS->HandleProtocol (Image->DeviceHandle, &gEfiSimpleFileSystemProtocolGuid,
                              (VOID **)&FileSystem);
  if (EFI_ERROR (Status) || FileSystem == NULL) {
    return EFI_NOT_FOUND;
  }
  Status = FileSystem->OpenVolume (FileSystem, &Root);
  if (EFI_ERROR (Status) || Root == NULL) {
    return EFI_NOT_FOUND;
  }
  for (Index = 0; Index < 3; Index++) {
    Status = ReadBoundedFile (Root, Names[Index], Auth[Index], AUTH_CAPACITY + 1, &AuthSize[Index]);
    if (EFI_ERROR (Status)) {
      break;
    }
    if (AuthSize[Index] > AUTH_CAPACITY) {
      Status = EFI_COMPROMISED_DATA;
      break;
    }
  }
  if (!EFI_ERROR (Status)) {
    Status = ReadBoundedFile (Root, L"\\PK.ESL", Esl, ESL_SIZE + 1, &EslSize);
    if (!EFI_ERROR (Status) && EslSize != ESL_SIZE) {
      Status = EFI_COMPROMISED_DATA;
    }
  }
  CloseStatus = Root->Close (Root);
  if (!EFI_ERROR (Status) && EFI_ERROR (CloseStatus)) {
    Status = CloseStatus;
  }
  if (!EFI_ERROR (Status)) {
    *DeviceHandle = Image->DeviceHandle;
  }
  return Status;
}

STATIC EFI_STATUS
SetAndReadVariable (CHAR16 *Name, EFI_GUID *Guid, UINT8 *Auth, UINTN AuthSize,
                    CONST UINT8 Esl[ESL_SIZE + 1])
{
  UINT8 Readback[ESL_SIZE + 1];
  UINTN Size = sizeof (Readback);
  UINT32 Attributes = 0;
  EFI_STATUS Status;

  Status = gRT->SetVariable (Name, Guid, TRUST_ATTRIBUTES, AuthSize, Auth);
  Print (L"mvo.positive-trust-chain.update variable=%s status=%r\n", Name, Status);
  if (Status != EFI_SUCCESS) {
    return Status;
  }
  ZeroMem (Readback, sizeof (Readback));
  Status = gRT->GetVariable (Name, Guid, &Attributes, &Size, Readback);
  if (Status != EFI_SUCCESS) {
    return Status;
  }
  if (Size != ESL_SIZE || Attributes != TRUST_ATTRIBUTES || CompareMem (Readback, Esl, ESL_SIZE) != 0) {
    return EFI_COMPROMISED_DATA;
  }
  return EFI_SUCCESS;
}

EFI_STATUS EFIAPI
UefiMain (EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
{
  UINT8 Auth[3][AUTH_CAPACITY + 1];
  UINT8 Esl[ESL_SIZE + 1];
  UINTN AuthSize[3] = { 0, 0, 0 };
  EFI_HANDLE DeviceHandle = NULL;
  EFI_HANDLE ChildHandle = NULL;
  EFI_DEVICE_PATH_PROTOCOL *ChildPath = NULL;
  CHAR16 *ExitData = NULL;
  UINTN ExitDataSize = 0;
  EFI_STATUS Status;
  EFI_EVENT CompletionEvent = NULL;
  UINTN EventIndex;
  UINTN Index;
  CONST CHAR8 *Stage = "architecture";

  (VOID)SystemTable;
  Print (L"mvo.positive-trust-chain.begin version=1\n");
#if !defined (MDE_CPU_AARCH64)
  Status = EFI_UNSUPPORTED;
  goto Failed;
#endif
  Stage = "initial-mode";
  Status = RequireMode (1, 0);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Stage = "requires-missing-pk";
  Status = RequireMissingPk ();
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Stage = "inputs";
  Status = ReadInputs (ImageHandle, Auth, AuthSize, Esl, &DeviceHandle);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Stage = "input-format";
  for (Index = 0; Index < 3; Index++) {
    Status = ValidateInputs (Auth[Index], AuthSize[Index], Esl);
    if (EFI_ERROR (Status)) {
      goto Failed;
    }
  }
  Stage = "pk-bootstrap";
  Status = SetAndReadVariable (L"PK", &gEfiGlobalVariableGuid, Auth[0], AuthSize[0], Esl);
  if (Status != EFI_SUCCESS) {
    goto Failed;
  }
  Stage = "user-mode";
  Status = RequireMode (0, 1);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Stage = "kek-update";
  Status = SetAndReadVariable (L"KEK", &gEfiGlobalVariableGuid, Auth[1], AuthSize[1], Esl);
  if (Status != EFI_SUCCESS) {
    goto Failed;
  }
  Stage = "db-update";
  Status = SetAndReadVariable (L"db", &gEfiImageSecurityDatabaseGuid, Auth[2], AuthSize[2], Esl);
  if (Status != EFI_SUCCESS) {
    goto Failed;
  }
  Stage = "before-image-mode";
  Status = RequireMode (0, 1);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Stage = "image-device-path";
  ChildPath = FileDevicePath (DeviceHandle, L"\\SIGNED.EFI");
  if (ChildPath == NULL) {
    Status = EFI_OUT_OF_RESOURCES;
    goto Failed;
  }
  Stage = "load-signed-image";
  Status = gBS->LoadImage (FALSE, ImageHandle, ChildPath, NULL, 0, &ChildHandle);
  FreePool (ChildPath);
  ChildPath = NULL;
  Print (L"mvo.positive-trust-chain.load status=%r\n", Status);
  if (Status != EFI_SUCCESS) {
    // LoadImage may return a handle with an error. It is never started here.
    if (ChildHandle != NULL) {
      gBS->UnloadImage (ChildHandle);
    }
    goto Failed;
  }
  if (ChildHandle == NULL) {
    Status = EFI_COMPROMISED_DATA;
    goto Failed;
  }
  Stage = "start-signed-image";
  Status = gBS->StartImage (ChildHandle, &ExitDataSize, &ExitData);
  Print (L"\nmvo.positive-trust-chain.start status=%r\n", Status);
  // Do not print a child's exit-data buffer. The original EFI application
  // returns through the normal loader path, which releases its image.
  if (ExitData != NULL) {
    FreePool (ExitData);
    ExitData = NULL;
  }
  if (Status != EFI_SUCCESS) {
    EFI_LOADED_IMAGE_PROTOCOL *LoadedChild = NULL;

    // A pre-entry StartImage failure can leave the owned image loaded. A
    // returned EFI application is already released by firmware, so first
    // check its protocol before cleanup and keep the actual start status.
    if (gBS->HandleProtocol (ChildHandle, &gEfiLoadedImageProtocolGuid,
                            (VOID **)&LoadedChild) == EFI_SUCCESS && LoadedChild != NULL) {
      gBS->UnloadImage (ChildHandle);
    }
    goto Failed;
  }
  Stage = "after-image-mode";
  Status = RequireMode (0, 1);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Stage = "completion-event";
  Status = gBS->CreateEvent (EVT_TIMER, TPL_APPLICATION, NULL, NULL, &CompletionEvent);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Status = gBS->SetTimer (CompletionEvent, TimerPeriodic, 10000000);
  if (EFI_ERROR (Status)) {
    gBS->CloseEvent (CompletionEvent);
    goto Failed;
  }
  Print (L"mvo.positive-trust-chain.complete attributes=0x00000027 setup-mode=0 secure-boot=1 pk-verified=1 kek-verified=1 db-verified=1 signed-image-executed=1\n");
  Stage = "completion-wait";
  for (;;) {
    Status = gBS->WaitForEvent (1, &CompletionEvent, &EventIndex);
    if (EFI_ERROR (Status) || EventIndex != 0) {
      if (!EFI_ERROR (Status)) {
        Status = EFI_COMPROMISED_DATA;
      }
      gBS->CloseEvent (CompletionEvent);
      goto Failed;
    }
  }

Failed:
  Print (L"mvo.positive-trust-chain.failure stage=%a status=%r\n", Stage, Status);
  return Status;
}
