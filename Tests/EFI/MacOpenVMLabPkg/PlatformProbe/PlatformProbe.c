// SPDX-License-Identifier: Apache-2.0
// Original bounded, read-only UEFI platform probe. Not a Windows compatibility test.
#include <Uefi.h>
#include <Guid/GlobalVariable.h>
#include <Protocol/Tcg2Protocol.h>
#include <Library/BaseMemoryLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>
#include <Library/UefiLib.h>

STATIC
UINT32
ReadBigEndian32 (CONST UINT8 *Bytes)
{
  return ((UINT32)Bytes[0] << 24) | ((UINT32)Bytes[1] << 16) |
         ((UINT32)Bytes[2] << 8) | (UINT32)Bytes[3];
}

STATIC
EFI_STATUS
ReadSecurityFlag (CHAR16 *Name, UINT8 *Value)
{
  UINTN Size = sizeof (*Value);
  UINT32 Attributes = 0;
  EFI_STATUS Status;

  *Value = 0xFF;
  Status = gRT->GetVariable (Name, &gEfiGlobalVariableGuid, &Attributes, &Size, Value);
  if (!EFI_ERROR (Status) && Size != sizeof (*Value)) {
    return EFI_COMPROMISED_DATA;
  }
  return Status;
}

EFI_STATUS
EFIAPI
UefiMain (EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
{
  EFI_STATUS Status;
  EFI_STATUS SetupStatus;
  EFI_STATUS SecureStatus;
  EFI_TCG2_PROTOCOL *Tcg2 = NULL;
  EFI_TCG2_BOOT_SERVICE_CAPABILITY Capability;
  UINT8 SetupMode;
  UINT8 SecureBoot;
  UINT8 Response[27];
  UINT32 ResponseSize;
  // TPM2_GetCapability(TPM_CAP_TPM_PROPERTIES, TPM_PT_MANUFACTURER, count=1).
  // This requests a public property; it neither clears nor provisions the TPM.
  UINT8 Command[22] = {
    0x80, 0x01, 0x00, 0x00, 0x00, 0x16, 0x00, 0x00, 0x01, 0x7A,
    0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x01, 0x05,
    0x00, 0x00, 0x00, 0x01
  };

  (VOID)ImageHandle;
  (VOID)SystemTable;
  Print (L"mvo.platform-probe.begin version=1\n");
#if defined (MDE_CPU_AARCH64)
  Print (L"mvo.platform-probe.arch=aarch64\n");
#else
  Print (L"mvo.platform-probe.arch=unexpected\n");
  return EFI_UNSUPPORTED;
#endif

  SetupStatus = ReadSecurityFlag (L"SetupMode", &SetupMode);
  SecureStatus = ReadSecurityFlag (L"SecureBoot", &SecureBoot);
  Print (L"mvo.platform-probe.setup status=%r value=%u\n", SetupStatus, (UINT32)SetupMode);
  Print (L"mvo.platform-probe.secure-boot status=%r value=%u\n", SecureStatus, (UINT32)SecureBoot);
  if (EFI_ERROR (SetupStatus) || EFI_ERROR (SecureStatus) || SetupMode > 1 || SecureBoot > 1) {
    Print (L"mvo.platform-probe.failure=security-variable-read\n");
    return EFI_COMPROMISED_DATA;
  }

  Status = gBS->LocateProtocol (&gEfiTcg2ProtocolGuid, NULL, (VOID **)&Tcg2);
  if (EFI_ERROR (Status) || Tcg2 == NULL) {
    Print (L"mvo.platform-probe.failure=tcg2-protocol status=%r\n", Status);
    return EFI_UNSUPPORTED;
  }
  ZeroMem (&Capability, sizeof (Capability));
  Capability.Size = (UINT8)sizeof (Capability);
  Status = Tcg2->GetCapability (Tcg2, &Capability);
  Print (L"mvo.platform-probe.tcg2 status=%r present=%u active-banks=0x%08x\n",
         Status, (UINT32)Capability.TPMPresentFlag, Capability.ActivePcrBanks);
  if (EFI_ERROR (Status) || Capability.Size != sizeof (Capability) ||
      Capability.StructureVersion.Major != 1 || Capability.StructureVersion.Minor != 1 ||
      Capability.ProtocolVersion.Major != 1 || Capability.ProtocolVersion.Minor != 1 ||
      !Capability.TPMPresentFlag ||
      !(Capability.HashAlgorithmBitmap & EFI_TCG2_BOOT_HASH_ALG_SHA256) ||
      !(Capability.ActivePcrBanks & EFI_TCG2_BOOT_HASH_ALG_SHA256) ||
      (Capability.ActivePcrBanks & ~Capability.HashAlgorithmBitmap) != 0 ||
      Capability.MaxCommandSize < sizeof (Command) ||
      Capability.MaxResponseSize < sizeof (Response)) {
    Print (L"mvo.platform-probe.failure=tcg2-capability\n");
    return EFI_DEVICE_ERROR;
  }

  ZeroMem (Response, sizeof (Response));
  Status = Tcg2->SubmitCommand (Tcg2, sizeof (Command), Command,
                              sizeof (Response), Response);
  if (EFI_ERROR (Status)) {
    Print (L"mvo.platform-probe.failure=tpm-command status=%r\n", Status);
    return EFI_DEVICE_ERROR;
  }
  ResponseSize = ReadBigEndian32 (&Response[2]);
  if (Response[0] != 0x80 || Response[1] != 0x01 ||
      ResponseSize != 27 ||
      ReadBigEndian32 (&Response[6]) != 0 || Response[10] > 1 ||
      ReadBigEndian32 (&Response[11]) != 6 ||
      ReadBigEndian32 (&Response[15]) != 1 ||
      ReadBigEndian32 (&Response[19]) != 0x105) {
    Print (L"mvo.platform-probe.failure=tpm-response\n");
    return EFI_COMPROMISED_DATA;
  }
  Print (L"mvo.platform-probe.tpm-public-manufacturer=0x%08x\n",
         ReadBigEndian32 (&Response[23]));
  Print (L"mvo.platform-probe.complete setup=%u secure-boot=%u\n",
         (UINT32)SetupMode, (UINT32)SecureBoot);
  return EFI_SUCCESS;
}
