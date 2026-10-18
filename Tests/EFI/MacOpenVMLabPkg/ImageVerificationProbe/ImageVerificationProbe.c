// SPDX-License-Identifier: Apache-2.0
// Original disposable image-verification experiment; never production trust.
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
#define ESL_SIZE 823U
#define TRUST_ATTRIBUTES 0x27U
#define DBX_SIZE 76U
#include "../PositiveTrustChainProbe/BoundedInputs.h"
#include "TrustChainInputs.h"

STATIC UINTN mFailures;

STATIC BOOLEAN
RunImage (EFI_HANDLE Parent, EFI_HANDLE Device, CONST CHAR8 *Name, CHAR16 *Path,
          BOOLEAN Allow, UINT8 Setup)
{
  EFI_DEVICE_PATH_PROTOCOL *FilePath;
  EFI_HANDLE Child = NULL;
  EFI_STATUS Status;
  EFI_STATUS StartStatus = EFI_NOT_STARTED;
  EFI_STATUS Cleanup = EFI_SUCCESS;
  EFI_LOADED_IMAGE_PROTOCOL *Loaded = NULL;
  CHAR16 *ExitData = NULL;
  UINTN ExitSize = 0;
  BOOLEAN Passed;
  BOOLEAN Mode;
  BOOLEAN HadHandle;

  Print (L"\nmvo.image-verification.begin-case name=%a\n", Name);
  FilePath = FileDevicePath (Device, Path);
  if (FilePath == NULL) {
    mFailures++;
    return FALSE;
  }
  Status = gBS->LoadImage (FALSE, Parent, FilePath, NULL, 0, &Child);
  FreePool (FilePath);
  HadHandle = Child != NULL;
  Print (L"\nmvo.image-verification.load name=%a status=0x%016lx handle=%u\n",
         Name, (UINT64)Status, (UINT32)HadHandle);
  if (Allow && Status == EFI_SUCCESS && Child != NULL) {
    StartStatus = gBS->StartImage (Child, &ExitSize, &ExitData);
    if (ExitData != NULL) {
      FreePool (ExitData);
    }
    Print (L"\nmvo.image-verification.start name=%a status=0x%016lx\n", Name, (UINT64)StartStatus);
    // Returned applications are normally unloaded by firmware. A pre-entry
    // failure may retain the owned handle, which must still be released.
    if (gBS->HandleProtocol (Child, &gEfiLoadedImageProtocolGuid, (VOID **)&Loaded) == EFI_SUCCESS) {
      Cleanup = gBS->UnloadImage (Child);
    }
  } else if (Child != NULL) {
    // An unexpectedly accepted negative image is a failure, never started.
    Cleanup = gBS->UnloadImage (Child);
  }
  Mode = RequireMode (Setup, Setup == 1 ? 0 : 1) == EFI_SUCCESS;
  Passed = Mode && Cleanup == EFI_SUCCESS &&
           (Allow ? Status == EFI_SUCCESS && HadHandle && StartStatus == EFI_SUCCESS :
                    Status == EFI_ACCESS_DENIED && !HadHandle);
  if (!Passed) {
    mFailures++;
  }
  Print (L"mvo.image-verification.end-case name=%a mode=%u cleanup=0x%016lx passed=%u\n",
         Name, (UINT32)Mode, (UINT64)Cleanup, (UINT32)Passed);
  return Passed;
}

STATIC EFI_STATUS
RevokeChild (EFI_HANDLE Device)
{
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *FileSystem = NULL;
  EFI_FILE_PROTOCOL *Root = NULL;
  UINT8 Auth[AUTH_CAPACITY + 1];
  UINT8 Esl[DBX_SIZE + 1];
  UINT8 Actual[DBX_SIZE + 1];
  UINTN AuthSize = 0;
  UINTN EslSize = 0;
  UINTN Size = 0;
  UINT32 Attributes = 0;
  UINT32 CertificateLength;
  EFI_STATUS Status;
  EFI_STATUS CloseStatus;

  Status = gRT->GetVariable (L"dbx", &gEfiImageSecurityDatabaseGuid, NULL, &Size, NULL);
  if (Status != EFI_NOT_FOUND) {
    return EFI_ACCESS_DENIED;
  }
  Status = gBS->HandleProtocol (Device, &gEfiSimpleFileSystemProtocolGuid, (VOID **)&FileSystem);
  if (EFI_ERROR (Status) || FileSystem == NULL) {
    return EFI_NOT_FOUND;
  }
  Status = FileSystem->OpenVolume (FileSystem, &Root);
  if (EFI_ERROR (Status) || Root == NULL) {
    return EFI_NOT_FOUND;
  }
  Status = ReadBoundedFile (Root, L"\\DBX.AUTH", Auth, sizeof (Auth), &AuthSize);
  if (!EFI_ERROR (Status)) {
    Status = ReadBoundedFile (Root, L"\\DBX.ESL", Esl, sizeof (Esl), &EslSize);
  }
  CloseStatus = Root->Close (Root);
  if (EFI_ERROR (Status) || EFI_ERROR (CloseStatus)) {
    return EFI_ERROR (Status) ? Status : CloseStatus;
  }
  if (EslSize != DBX_SIZE || AuthSize < 41 + DBX_SIZE || AuthSize > AUTH_CAPACITY) {
    return EFI_COMPROMISED_DATA;
  }
  CertificateLength = ReadLe32 (Auth + 16);
  if (CompareMem (Esl, &gEfiCertSha256Guid, sizeof (EFI_GUID)) != 0 ||
      ReadLe32 (Esl + 16) != DBX_SIZE || ReadLe32 (Esl + 20) != 0 || ReadLe32 (Esl + 24) != 48 ||
      CertificateLength < 25 || CertificateLength > AuthSize - 16 - DBX_SIZE ||
      AuthSize != 16 + (UINTN)CertificateLength + DBX_SIZE || !ValidTimestamp (Auth) ||
      ReadLe16 (Auth + 20) != 0x0200 || ReadLe16 (Auth + 22) != WIN_CERT_TYPE_EFI_GUID ||
      CompareMem (Auth + 24, &gEfiCertPkcs7Guid, sizeof (EFI_GUID)) != 0 ||
      CompareMem (Auth + 16 + CertificateLength, Esl, DBX_SIZE) != 0) {
    return EFI_COMPROMISED_DATA;
  }
  Status = gRT->SetVariable (L"dbx", &gEfiImageSecurityDatabaseGuid, TRUST_ATTRIBUTES, AuthSize, Auth);
  Print (L"mvo.image-verification.revoke status=0x%016lx\n", (UINT64)Status);
  if (EFI_ERROR (Status)) {
    return Status;
  }
  Size = sizeof (Actual);
  Status = gRT->GetVariable (L"dbx", &gEfiImageSecurityDatabaseGuid, &Attributes, &Size, Actual);
  if (EFI_ERROR (Status) || Size != DBX_SIZE || Attributes != TRUST_ATTRIBUTES ||
      CompareMem (Actual, Esl, DBX_SIZE) != 0 || RequireMode (0, 1) != EFI_SUCCESS) {
    return EFI_COMPROMISED_DATA;
  }
  Print (L"mvo.image-verification.revocation-readback exact=1 bytes=76 attributes=0x00000027\n");
  return EFI_SUCCESS;
}

EFI_STATUS EFIAPI
UefiMain (EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
{
  UINT8 Auth[3][AUTH_CAPACITY + 1];
  UINTN AuthSize[3] = { 0, 0, 0 };
  UINT8 Esl[ESL_SIZE + 1];
  EFI_HANDLE Device = NULL;
  EFI_STATUS Status;
  EFI_EVENT Event = NULL;
  UINTN Index;
  UINTN EventIndex;
  CONST CHAR8 *Stage = "fresh-setup";
  (VOID)SystemTable;
  Print (L"mvo.image-verification.begin version=1\n");
  Status = RequireMode (1, 0);
  if (EFI_ERROR (Status) || EFI_ERROR (RequireMissingPk ())) {
    Status = EFI_ACCESS_DENIED;
    goto Failed;
  }
  Stage = "inputs";
  Status = ReadInputs (ImageHandle, Auth, AuthSize, Esl, &Device);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  for (Index = 0; Index < 3; Index++) {
    Status = ValidateInputs (Auth[Index], AuthSize[Index], Esl);
    if (EFI_ERROR (Status)) {
      goto Failed;
    }
  }
  Stage = "setup-image-controls";
  if (!RunImage (ImageHandle, Device, "setup-unsigned", L"\\UNSIGNED.EFI", TRUE, 1) ||
      !RunImage (ImageHandle, Device, "setup-altered", L"\\ALTERED.EFI", TRUE, 1)) {
    Status = EFI_COMPROMISED_DATA;
    goto Failed;
  }
  Stage = "enrollment";
  Status = SetAndReadVariable (L"PK", &gEfiGlobalVariableGuid, Auth[0], AuthSize[0], Esl);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Status = SetAndReadVariable (L"KEK", &gEfiGlobalVariableGuid, Auth[1], AuthSize[1], Esl);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Status = SetAndReadVariable (L"db", &gEfiImageSecurityDatabaseGuid, Auth[2], AuthSize[2], Esl);
  if (EFI_ERROR (Status) || RequireMode (0, 1) != EFI_SUCCESS) {
    Status = EFI_COMPROMISED_DATA;
    goto Failed;
  }
  RunImage (ImageHandle, Device, "trusted-before", L"\\SIGNED.EFI", TRUE, 0);
  RunImage (ImageHandle, Device, "unsigned-user", L"\\UNSIGNED.EFI", FALSE, 0);
  RunImage (ImageHandle, Device, "altered-user", L"\\ALTERED.EFI", FALSE, 0);
  RunImage (ImageHandle, Device, "trusted-after", L"\\SIGNED.EFI", TRUE, 0);
  Stage = "revocation";
  Status = RevokeChild (Device);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  RunImage (ImageHandle, Device, "unrevoked-before", L"\\ALLOWED.EFI", TRUE, 0);
  RunImage (ImageHandle, Device, "revoked-signed", L"\\SIGNED.EFI", FALSE, 0);
  RunImage (ImageHandle, Device, "unrevoked-after", L"\\ALLOWED.EFI", TRUE, 0);
  Stage = "completion-event";
  Status = gBS->CreateEvent (EVT_TIMER, TPL_APPLICATION, NULL, NULL, &Event);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Status = gBS->SetTimer (Event, TimerPeriodic, 10000000);
  if (EFI_ERROR (Status)) {
    gBS->CloseEvent (Event);
    goto Failed;
  }
  Print (L"mvo.image-verification.complete cases=9 failures=%u\n", (UINT32)mFailures);
  for (;;) {
    Status = gBS->WaitForEvent (1, &Event, &EventIndex);
    if (EFI_ERROR (Status) || EventIndex != 0) {
      gBS->CloseEvent (Event);
      Status = EFI_DEVICE_ERROR;
      goto Failed;
    }
  }
Failed:
  Print (L"mvo.image-verification.failure stage=%a status=%r\n", Stage, Status);
  return Status;
}
