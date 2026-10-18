// SPDX-License-Identifier: Apache-2.0
// Original offline AUTH2 replacement tests. Published test trust only.
#include <Uefi.h>
#include <Guid/GlobalVariable.h>
#include <Guid/ImageAuthentication.h>
#include <Guid/WinCertificate.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>
#include <Library/BaseMemoryLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>
#include <Library/UefiLib.h>
#include "../PkEnrollmentProbe/FixtureCertificate.h"

#define AUTH_CAPACITY 8192U
#define ESL_SIZE 823U
#define TRUST_ATTRIBUTES 0x27U
#include "../PositiveTrustChainProbe/BoundedInputs.h"

STATIC UINT8 mAuth[5][AUTH_CAPACITY + 1];
STATIC UINT8 mEsl[5][ESL_SIZE + 1];
STATIC UINTN mSize[5];
STATIC UINTN mFailures;

STATIC EFI_STATUS
ReadInputs (EFI_HANDLE ImageHandle)
{
  EFI_LOADED_IMAGE_PROTOCOL *Image = NULL;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *FileSystem = NULL;
  EFI_FILE_PROTOCOL *Root = NULL;
  STATIC CHAR16 *AuthNames[] = { L"\\PK.AUTH", L"\\KEK0.AUTH", L"\\KEK1.AUTH",
                                L"\\KEK2.AUTH", L"\\EQUAL.AUTH" };
  STATIC CHAR16 *EslNames[] = { L"\\PK.ESL", L"\\KEK0.ESL", L"\\KEK1.ESL",
                               L"\\KEK2.ESL", L"\\EQUAL.ESL" };
  UINTN Index;
  UINTN Size;
  EFI_STATUS Status;
  EFI_STATUS CloseStatus;

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
  for (Index = 0; Index < 5; Index++) {
    Status = ReadBoundedFile (Root, AuthNames[Index], mAuth[Index], sizeof (mAuth[Index]), &mSize[Index]);
    if (EFI_ERROR (Status)) {
      break;
    }
    Status = ReadBoundedFile (Root, EslNames[Index], mEsl[Index], sizeof (mEsl[Index]), &Size);
    if (EFI_ERROR (Status) || Size != ESL_SIZE) {
      Status = EFI_COMPROMISED_DATA;
      break;
    }
    Status = ValidateInputs (mAuth[Index], mSize[Index], mEsl[Index]);
    if (EFI_ERROR (Status)) {
      break;
    }
  }
  CloseStatus = Root->Close (Root);
  return EFI_ERROR (Status) ? Status : CloseStatus;
}

STATIC BOOLEAN
Attempt (CONST CHAR8 *Case, CHAR16 *Name, UINT8 *Data, UINTN Size,
         EFI_STATUS ExpectedStatus, CONST UINT8 *ExpectedEsl)
{
  UINT8 Readback[ESL_SIZE + 1];
  UINTN ReadSize = sizeof (Readback);
  UINT32 Attributes = 0;
  EFI_STATUS Status;
  EFI_STATUS ReadStatus;
  BOOLEAN Matches;
  BOOLEAN Mode;
  BOOLEAN Passed;

  Status = gRT->SetVariable (Name, &gEfiGlobalVariableGuid, TRUST_ATTRIBUTES, Size, Data);
  ZeroMem (Readback, sizeof (Readback));
  ReadStatus = gRT->GetVariable (Name, &gEfiGlobalVariableGuid, &Attributes, &ReadSize, Readback);
  Matches = ReadStatus == EFI_SUCCESS && ReadSize == ESL_SIZE && Attributes == TRUST_ATTRIBUTES &&
            CompareMem (Readback, ExpectedEsl, ESL_SIZE) == 0;
  Mode = RequireMode (0, 1) == EFI_SUCCESS;
  Passed = Status == ExpectedStatus && Matches && Mode;
  if (!Passed) {
    mFailures++;
  }
  Print (L"mvo.auth-variable.case name=%a status=0x%016lx expected=0x%016lx readback=%u mode=%u passed=%u\n",
         Case, (UINT64)Status, (UINT64)ExpectedStatus, (UINT32)Matches, (UINT32)Mode, (UINT32)Passed);
  return Passed;
}

EFI_STATUS EFIAPI
UefiMain (EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
{
  UINT8 Mutated[AUTH_CAPACITY + 1];
  UINTN SignatureEnd;
  EFI_STATUS Status;
  EFI_EVENT Event = NULL;
  UINTN EventIndex;
  CONST CHAR8 *Stage = "architecture";

  (VOID)SystemTable;
  Print (L"mvo.auth-variable.begin version=1\n");
#if !defined (MDE_CPU_AARCH64)
  Status = EFI_UNSUPPORTED;
  goto Failed;
#endif
  Stage = "fresh-setup";
  Status = RequireMode (1, 0);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Status = RequireMissingPk ();
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Stage = "inputs";
  Status = ReadInputs (ImageHandle);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Stage = "positive-baseline";
  if (!Attempt ("pk-bootstrap", L"PK", mAuth[0], mSize[0], EFI_SUCCESS, mEsl[0]) ||
      !Attempt ("kek-initial", L"KEK", mAuth[1], mSize[1], EFI_SUCCESS, mEsl[1]) ||
      !Attempt ("kek-newer", L"KEK", mAuth[2], mSize[2], EFI_SUCCESS, mEsl[2])) {
    Status = EFI_COMPROMISED_DATA;
    goto Failed;
  }
  // Keep observing negative cases after a policy failure; never label the run passed.
  Attempt ("older-timestamp", L"KEK", mAuth[1], mSize[1], EFI_SECURITY_VIOLATION, mEsl[2]);
  CopyMem (Mutated, mAuth[3], mSize[3]);
  SignatureEnd = 16 + ReadLe32 (Mutated + 16);
  Mutated[SignatureEnd + 28] ^= 1; // SignatureOwner inside signed ESL, still a valid GUID.
  Attempt ("tampered-payload", L"KEK", Mutated, mSize[3], EFI_SECURITY_VIOLATION, mEsl[2]);
  CopyMem (Mutated, mAuth[3], mSize[3]);
  Mutated[SignatureEnd - 1] ^= 1; // Last RSA signature octet; DER structure stays intact.
  Attempt ("tampered-signature", L"KEK", Mutated, mSize[3], EFI_SECURITY_VIOLATION, mEsl[2]);
  Attempt ("missing-auth", L"KEK", mEsl[3], ESL_SIZE, EFI_SECURITY_VIOLATION, mEsl[2]);
  Attempt ("truncated-auth", L"KEK", mAuth[3], 39, EFI_SECURITY_VIOLATION, mEsl[2]);
  Attempt ("equal-replay", L"KEK", mAuth[2], mSize[2], EFI_SECURITY_VIOLATION, mEsl[2]);
  Attempt ("equal-replacement", L"KEK", mAuth[4], mSize[4], EFI_SECURITY_VIOLATION, mEsl[2]);
  Attempt ("valid-after-rejections", L"KEK", mAuth[3], mSize[3], EFI_SUCCESS, mEsl[3]);
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
  Print (L"mvo.auth-variable.complete cases=11 failures=%u\n", (UINT32)mFailures);
  Stage = "completion-wait";
  for (;;) {
    Status = gBS->WaitForEvent (1, &Event, &EventIndex);
    if (EFI_ERROR (Status) || EventIndex != 0) {
      gBS->CloseEvent (Event);
      Status = EFI_DEVICE_ERROR;
      goto Failed;
    }
  }
Failed:
  Print (L"mvo.auth-variable.failure stage=%a status=%r\n", Stage, Status);
  return Status;
}
