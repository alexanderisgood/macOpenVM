// SPDX-License-Identifier: Apache-2.0
// Original fixture-only TPM NV persistence payload. These are unsigned lab apps.
#include <Uefi.h>
#include <Guid/GlobalVariable.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>
#include <Protocol/Tcg2Protocol.h>
#include <Library/BaseMemoryLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>
#include <Library/UefiLib.h>

#if defined (MVO_NV_VERIFY_ONLY) && MVO_NV_VERIFY_ONLY != 1
#error The verification build must use MVO_NV_VERIFY_ONLY=1.
#endif

#define NV_INDEX              0x01804D56U
#define NV_OWNER_ATTRIBUTES   0x00020002U
#define NV_WRITTEN_ATTRIBUTES 0x20020002U
#define TPM_OWNER             0x40000001U
#define TPM_MISSING_NV_INDEX  0x0000018BU
#define NONCE_SIZE            32U
#define RESPONSE_CAPACITY     64U

#if defined (MVO_NV_VERIFY_ONLY)
STATIC CONST CHAR8 mPhase[] = "verify";
#define EXPECTED_COMMAND_COUNT 2U
#define REQUIRED_COMMAND_SIZE 35U
#else
STATIC CONST CHAR8 mPhase[] = "prepare";
#define EXPECTED_COMMAND_COUNT 5U
#define REQUIRED_COMMAND_SIZE 67U
#endif

STATIC UINT32 mCommandCount;
STATIC CONST UINT8 mPasswordSession[9] = {
  0x40, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00
};

// 000B || SHA256(01804D56 || 000B || 20020002 || 0000 || 0020).
// The hash covers TPMS_NV_PUBLIC, excluding its TPM2B size prefix and NV data.
STATIC CONST UINT8 mWrittenNvName[34] = {
  0x00, 0x0B, 0x6B, 0x60, 0xE3, 0xC2, 0x14, 0x76, 0xEA, 0x87, 0x43, 0xC7,
  0x83, 0x6C, 0xDF, 0x80, 0x63, 0x2E, 0x99, 0x50, 0x34, 0xA7, 0xEB, 0x08,
  0xD8, 0x5D, 0x9A, 0x14, 0x05, 0x62, 0x27, 0xF2, 0x76, 0xAE
};

STATIC UINT16
ReadBe16 (CONST UINT8 *Bytes)
{
  return (UINT16)(((UINT16)Bytes[0] << 8) | Bytes[1]);
}

STATIC UINT32
ReadBe32 (CONST UINT8 *Bytes)
{
  return ((UINT32)Bytes[0] << 24) | ((UINT32)Bytes[1] << 16) |
         ((UINT32)Bytes[2] << 8) | Bytes[3];
}

STATIC VOID
WriteBe16 (UINT8 *Bytes, UINT16 Value)
{
  Bytes[0] = (UINT8)(Value >> 8);
  Bytes[1] = (UINT8)Value;
}

STATIC VOID
WriteBe32 (UINT8 *Bytes, UINT32 Value)
{
  Bytes[0] = (UINT8)(Value >> 24);
  Bytes[1] = (UINT8)(Value >> 16);
  Bytes[2] = (UINT8)(Value >> 8);
  Bytes[3] = (UINT8)Value;
}

STATIC VOID
WriteHeader (UINT8 *Command, UINT16 Tag, UINT32 Size, UINT32 Code)
{
  WriteBe16 (Command, Tag);
  WriteBe32 (Command + 2, Size);
  WriteBe32 (Command + 6, Code);
}

STATIC EFI_STATUS
RequireSetupMode (VOID)
{
  UINT8 Setup = 0xFF;
  UINT8 Secure = 0xFF;
  UINTN Size = sizeof (Setup);
  EFI_STATUS Status;

  Status = gRT->GetVariable (L"SetupMode", &gEfiGlobalVariableGuid, NULL, &Size, &Setup);
  if (EFI_ERROR (Status) || Size != sizeof (Setup) || Setup != 1) {
    return EFI_ACCESS_DENIED;
  }
  Size = sizeof (Secure);
  Status = gRT->GetVariable (L"SecureBoot", &gEfiGlobalVariableGuid, NULL, &Size, &Secure);
  if (EFI_ERROR (Status) || Size != sizeof (Secure) || Secure != 0) {
    return EFI_ACCESS_DENIED;
  }
  return EFI_SUCCESS;
}

STATIC EFI_STATUS
ReadNonce (EFI_HANDLE ImageHandle, UINT8 Nonce[NONCE_SIZE])
{
  EFI_LOADED_IMAGE_PROTOCOL *Image = NULL;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *FileSystem = NULL;
  EFI_FILE_PROTOCOL *Root = NULL;
  EFI_FILE_PROTOCOL *File = NULL;
  UINT8 Buffer[NONCE_SIZE + 1];
  UINT8 Extra = 0;
  UINTN Size = sizeof (Buffer);
  UINTN ExtraSize = sizeof (Extra);
  UINTN Index;
  EFI_STATUS Status;
  EFI_STATUS CloseStatus;

  ZeroMem (Buffer, sizeof (Buffer));
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
  Status = Root->Open (Root, &File, L"\\MVO-NV-NONCE.TXT", EFI_FILE_MODE_READ, 0);
  if (!EFI_ERROR (Status) && File != NULL) {
    // Reading one byte beyond the required payload rejects any extra byte,
    // including a newline, without trusting an unbounded file-size field.
    Status = File->Read (File, &Size, Buffer);
    if (!EFI_ERROR (Status) && Size == NONCE_SIZE) {
      Status = File->Read (File, &ExtraSize, &Extra);
      if (!EFI_ERROR (Status) && ExtraSize != 0) {
        Status = EFI_COMPROMISED_DATA;
      }
    }
    CloseStatus = File->Close (File);
    if (!EFI_ERROR (Status) && EFI_ERROR (CloseStatus)) {
      Status = CloseStatus;
    }
  } else if (!EFI_ERROR (Status)) {
    Status = EFI_COMPROMISED_DATA;
  }
  CloseStatus = Root->Close (Root);
  if (!EFI_ERROR (Status) && EFI_ERROR (CloseStatus)) {
    Status = CloseStatus;
  }
  if (EFI_ERROR (Status)) {
    return Status;
  }
  if (Size != NONCE_SIZE) {
    return EFI_COMPROMISED_DATA;
  }
  for (Index = 0; Index < NONCE_SIZE; Index++) {
    if (!((Buffer[Index] >= '0' && Buffer[Index] <= '9') ||
          (Buffer[Index] >= 'a' && Buffer[Index] <= 'f'))) {
      return EFI_COMPROMISED_DATA;
    }
  }
  CopyMem (Nonce, Buffer, NONCE_SIZE);
  return EFI_SUCCESS;
}

STATIC EFI_STATUS
Submit (EFI_TCG2_PROTOCOL *Tcg2, UINT8 *Command, UINT32 CommandSize,
        UINT8 Response[RESPONSE_CAPACITY], UINT32 *ResponseSize, UINT32 *ResponseCode)
{
  EFI_STATUS Status;

  ZeroMem (Response, RESPONSE_CAPACITY);
  *ResponseSize = 0;
  *ResponseCode = 0xFFFFFFFFU;
  mCommandCount++;
  Status = Tcg2->SubmitCommand (Tcg2, CommandSize, Command, RESPONSE_CAPACITY, Response);
  if (!EFI_ERROR (Status)) {
    *ResponseSize = ReadBe32 (Response + 2);
    if (*ResponseSize < 10 || *ResponseSize > RESPONSE_CAPACITY) {
      Status = EFI_COMPROMISED_DATA;
    } else {
      *ResponseCode = ReadBe32 (Response + 6);
    }
  }
  Print (L"mvo.nv-probe.command phase=%a code=0x%08x status=%r rc=0x%08x response-bytes=%u\n",
         mPhase, ReadBe32 (Command + 6), Status, *ResponseCode, *ResponseSize);
  return Status;
}

STATIC EFI_STATUS
CheckPasswordResponse (CONST UINT8 *Response, UINT32 Size, UINT32 Code, UINT32 ParameterSize)
{
  UINT32 SessionOffset;

  if (Code != 0) {
    return EFI_DEVICE_ERROR;
  }
  if (Size != 19 + ParameterSize || ReadBe16 (Response) != 0x8002 ||
      ReadBe32 (Response + 10) != ParameterSize) {
    return EFI_COMPROMISED_DATA;
  }
  SessionOffset = 14 + ParameterSize;
  // Password authorization has no allocated session or nonce. Its response
  // nevertheless sets continueSession=1, even when the request flag was zero.
  if (ReadBe16 (Response + SessionOffset) != 0 ||
      Response[SessionOffset + 2] != 1 ||
      ReadBe16 (Response + SessionOffset + 3) != 0) {
    return EFI_COMPROMISED_DATA;
  }
  return EFI_SUCCESS;
}

STATIC EFI_STATUS
ReadWrittenPublic (EFI_TCG2_PROTOCOL *Tcg2)
{
  UINT8 Command[14];
  UINT8 Response[RESPONSE_CAPACITY];
  UINT32 Size;
  UINT32 Code;
  EFI_STATUS Status;

  WriteHeader (Command, 0x8001, sizeof (Command), 0x00000169);
  WriteBe32 (Command + 10, NV_INDEX);
  Status = Submit (Tcg2, Command, sizeof (Command), Response, &Size, &Code);
  if (EFI_ERROR (Status)) {
    return Status;
  }
  if (Code != 0) {
    return EFI_DEVICE_ERROR;
  }
  if (Size != 62 || ReadBe16 (Response) != 0x8001 ||
      ReadBe16 (Response + 10) != 14 || ReadBe32 (Response + 12) != NV_INDEX ||
      ReadBe16 (Response + 16) != 0x000B ||
      ReadBe32 (Response + 18) != NV_WRITTEN_ATTRIBUTES ||
      ReadBe16 (Response + 22) != 0 || ReadBe16 (Response + 24) != NONCE_SIZE ||
      ReadBe16 (Response + 26) != sizeof (mWrittenNvName) ||
      CompareMem (Response + 28, mWrittenNvName, sizeof (mWrittenNvName)) != 0) {
    return EFI_COMPROMISED_DATA;
  }
  return EFI_SUCCESS;
}

STATIC EFI_STATUS
ReadAndCompareNv (EFI_TCG2_PROTOCOL *Tcg2, CONST UINT8 Nonce[NONCE_SIZE])
{
  UINT8 Command[35];
  UINT8 Response[RESPONSE_CAPACITY];
  UINT32 Size;
  UINT32 Code;
  EFI_STATUS Status;

  WriteHeader (Command, 0x8002, sizeof (Command), 0x0000014E);
  WriteBe32 (Command + 10, TPM_OWNER);
  WriteBe32 (Command + 14, NV_INDEX);
  WriteBe32 (Command + 18, sizeof (mPasswordSession));
  CopyMem (Command + 22, mPasswordSession, sizeof (mPasswordSession));
  WriteBe16 (Command + 31, NONCE_SIZE);
  WriteBe16 (Command + 33, 0);
  Status = Submit (Tcg2, Command, sizeof (Command), Response, &Size, &Code);
  if (EFI_ERROR (Status)) {
    return Status;
  }
  Status = CheckPasswordResponse (Response, Size, Code, 34);
  if (EFI_ERROR (Status)) {
    return Status;
  }
  if (ReadBe16 (Response + 14) != NONCE_SIZE ||
      CompareMem (Response + 16, Nonce, NONCE_SIZE) != 0) {
    return EFI_COMPROMISED_DATA;
  }
  return EFI_SUCCESS;
}

#if !defined (MVO_NV_VERIFY_ONLY)
// This entire block is removed from the verification translation unit.
STATIC EFI_STATUS
RequireMissingNv (EFI_TCG2_PROTOCOL *Tcg2)
{
  UINT8 Command[14];
  UINT8 Response[RESPONSE_CAPACITY];
  UINT32 Size;
  UINT32 Code;
  EFI_STATUS Status;

  WriteHeader (Command, 0x8001, sizeof (Command), 0x00000169);
  WriteBe32 (Command + 10, NV_INDEX);
  Status = Submit (Tcg2, Command, sizeof (Command), Response, &Size, &Code);
  if (EFI_ERROR (Status)) {
    return Status;
  }
  // Even an existing index with the expected public fields is a collision.
  // Never infer ownership from familiar data and never redefine an index.
  if (Code == 0) {
    return EFI_ACCESS_DENIED;
  }
  if (ReadBe16 (Response) != 0x8001 || Size != 10 || Code != TPM_MISSING_NV_INDEX) {
    return EFI_DEVICE_ERROR;
  }
  return EFI_SUCCESS;
}

STATIC EFI_STATUS
DefineNv (EFI_TCG2_PROTOCOL *Tcg2)
{
  UINT8 Command[45];
  UINT8 Response[RESPONSE_CAPACITY];
  UINT32 Size;
  UINT32 Code;
  EFI_STATUS Status;

  ZeroMem (Command, sizeof (Command));
  WriteHeader (Command, 0x8002, sizeof (Command), 0x0000012A);
  WriteBe32 (Command + 10, TPM_OWNER);
  WriteBe32 (Command + 14, sizeof (mPasswordSession));
  CopyMem (Command + 18, mPasswordSession, sizeof (mPasswordSession));
  // Empty index auth; the only access paths are owner read/write.
  WriteBe16 (Command + 29, 14);
  WriteBe32 (Command + 31, NV_INDEX);
  WriteBe16 (Command + 35, 0x000B);
  WriteBe32 (Command + 37, NV_OWNER_ATTRIBUTES);
  WriteBe16 (Command + 43, NONCE_SIZE);
  Status = Submit (Tcg2, Command, sizeof (Command), Response, &Size, &Code);
  return EFI_ERROR (Status) ? Status : CheckPasswordResponse (Response, Size, Code, 0);
}

STATIC EFI_STATUS
WriteNv (EFI_TCG2_PROTOCOL *Tcg2, CONST UINT8 Nonce[NONCE_SIZE])
{
  UINT8 Command[67];
  UINT8 Response[RESPONSE_CAPACITY];
  UINT32 Size;
  UINT32 Code;
  EFI_STATUS Status;

  WriteHeader (Command, 0x8002, sizeof (Command), 0x00000137);
  WriteBe32 (Command + 10, TPM_OWNER);
  WriteBe32 (Command + 14, NV_INDEX);
  WriteBe32 (Command + 18, sizeof (mPasswordSession));
  CopyMem (Command + 22, mPasswordSession, sizeof (mPasswordSession));
  WriteBe16 (Command + 31, NONCE_SIZE);
  CopyMem (Command + 33, Nonce, NONCE_SIZE);
  WriteBe16 (Command + 65, 0);
  Status = Submit (Tcg2, Command, sizeof (Command), Response, &Size, &Code);
  return EFI_ERROR (Status) ? Status : CheckPasswordResponse (Response, Size, Code, 0);
}
#endif

EFI_STATUS EFIAPI
UefiMain (EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
{
  EFI_STATUS Status;
  EFI_TCG2_PROTOCOL *Tcg2 = NULL;
  EFI_TCG2_BOOT_SERVICE_CAPABILITY Capability;
  EFI_EVENT CompletionEvent = NULL;
  UINTN EventIndex;
  UINT8 Nonce[NONCE_SIZE];
  CONST CHAR8 *Stage = "architecture";

  (VOID)SystemTable;
  Print (L"mvo.nv-probe.begin version=1 phase=%a index=0x%08x\n", mPhase, NV_INDEX);
#if !defined (MDE_CPU_AARCH64)
  Status = EFI_UNSUPPORTED;
  goto Failed;
#endif
  Stage = "requires-setup-mode";
  Status = RequireSetupMode ();
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Stage = "nonce-file";
  Status = ReadNonce (ImageHandle, Nonce);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Stage = "tcg2-protocol";
  Status = gBS->LocateProtocol (&gEfiTcg2ProtocolGuid, NULL, (VOID **)&Tcg2);
  if (EFI_ERROR (Status) || Tcg2 == NULL) {
    Status = EFI_UNSUPPORTED;
    goto Failed;
  }
  Stage = "tcg2-capability";
  ZeroMem (&Capability, sizeof (Capability));
  Capability.Size = (UINT8)sizeof (Capability);
  Status = Tcg2->GetCapability (Tcg2, &Capability);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  if (Capability.Size != sizeof (Capability) ||
      Capability.StructureVersion.Major != 1 || Capability.StructureVersion.Minor != 1 ||
      Capability.ProtocolVersion.Major != 1 || Capability.ProtocolVersion.Minor != 1 ||
      !Capability.TPMPresentFlag ||
      !(Capability.HashAlgorithmBitmap & EFI_TCG2_BOOT_HASH_ALG_SHA256) ||
      !(Capability.ActivePcrBanks & EFI_TCG2_BOOT_HASH_ALG_SHA256) ||
      (Capability.ActivePcrBanks & ~Capability.HashAlgorithmBitmap) != 0 ||
      Capability.MaxCommandSize < REQUIRED_COMMAND_SIZE ||
      Capability.MaxResponseSize < RESPONSE_CAPACITY) {
    Status = EFI_DEVICE_ERROR;
    goto Failed;
  }
#if !defined (MVO_NV_VERIFY_ONLY)
  Stage = "requires-missing-index";
  Status = RequireMissingNv (Tcg2);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Stage = "define-index";
  Status = DefineNv (Tcg2);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Stage = "write-marker";
  Status = WriteNv (Tcg2, Nonce);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
#endif
  Stage = "read-public";
  Status = ReadWrittenPublic (Tcg2);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Stage = "read-marker";
  Status = ReadAndCompareNv (Tcg2, Nonce);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Stage = "command-count";
  if (mCommandCount != EXPECTED_COMMAND_COUNT) {
    Status = EFI_COMPROMISED_DATA;
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
  Print (L"mvo.nv-probe.complete phase=%a index=0x%08x bytes=32 commands=%u marker-verified=1\n",
         mPhase, NV_INDEX, mCommandCount);
  // Remain in this trusted payload until the fixture owner stops QEMU. Returning
  // could let firmware launch the prepare app again and encounter its own index.
  // Firmware's event wait uses the normal interrupt/timer path, without polling
  // delays, further TPM requests, boot-service exit, or a reset.
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
  Print (L"mvo.nv-probe.failure phase=%a stage=%a status=%r\n", mPhase, Stage, Status);
  return Status;
}
