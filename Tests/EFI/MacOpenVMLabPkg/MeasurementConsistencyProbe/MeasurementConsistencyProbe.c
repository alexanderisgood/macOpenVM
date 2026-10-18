// SPDX-License-Identifier: Apache-2.0
// Original read-only measurement capture for a fresh, pinned, no-OS lab fixture.
// This does not establish event authenticity, Windows support, or platform trust.
#include <Uefi.h>
#include <IndustryStandard/UefiTcgPlatform.h>
#include <Protocol/Tcg2Protocol.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiLib.h>

// The host MUST pin the reviewed firmware and its Tcg2Dxe allocation/PCD build.
// GetEventLog has no allocation-length return. A descriptor alone does not
// establish allocation ownership. The reviewed provider allocates exactly
// PcdTcgLogAreaMinLen=0x10000 bytes with AllocatePages, before exposing its base.
#define PINNED_LOG_CAPACITY  65536U
#define MAP_CAPACITY         (1024U * 1024U)
#define MAX_DESCRIPTORS      4096U
#define MAX_EVENTS           1024U
#define MAX_ALGORITHMS       5U
#define PCR_RESPONSE_SIZE    164U

typedef struct {
  UINT16 Id;
  UINT16 Size;
  UINT32 Bank;
} LOG_ALGORITHM;

typedef struct {
  UINTN Used;
  UINTN LastOffset;
  UINT32 Events;
  UINT32 AlgorithmCount;
  LOG_ALGORITHM Algorithms[MAX_ALGORITHMS];
  UINT8 Errata;
  UINT8 Locality;
  BOOLEAN LocalityPresent;
} LOG_SUMMARY;

typedef struct {
  UINT32 Counter;
  UINT8 Values[4][32];
} PCR_SNAPSHOT;

STATIC UINT16
Little16 (CONST UINT8 *Bytes)
{
  return (UINT16)((UINT16)Bytes[0] | ((UINT16)Bytes[1] << 8));
}

STATIC UINT32
Little32 (CONST UINT8 *Bytes)
{
  return (UINT32)Bytes[0] | ((UINT32)Bytes[1] << 8) |
         ((UINT32)Bytes[2] << 16) | ((UINT32)Bytes[3] << 24);
}

STATIC UINT16
Big16 (CONST UINT8 *Bytes)
{
  return (UINT16)(((UINT16)Bytes[0] << 8) | (UINT16)Bytes[1]);
}

STATIC UINT32
Big32 (CONST UINT8 *Bytes)
{
  return ((UINT32)Bytes[0] << 24) | ((UINT32)Bytes[1] << 16) |
         ((UINT32)Bytes[2] << 8) | (UINT32)Bytes[3];
}

STATIC BOOLEAN
AllZero (CONST UINT8 *Bytes, UINTN Size)
{
  UINTN Index;
  for (Index = 0; Index < Size; Index++) {
    if (Bytes[Index] != 0) {
      return FALSE;
    }
  }
  return TRUE;
}

// Used exclusively with the owned 64KiB copy, never a firmware address.
STATIC BOOLEAN
Take (CONST UINT8 *Copy, UINTN Limit, UINTN *Offset, UINTN Length, CONST UINT8 **Bytes)
{
  if (*Offset > Limit || Length > Limit - *Offset) {
    return FALSE;
  }
  *Bytes = &Copy[*Offset];
  *Offset += Length;
  return TRUE;
}

STATIC BOOLEAN
KnownAlgorithm (UINT16 Id, LOG_ALGORITHM *Algorithm)
{
  Algorithm->Id = Id;
  switch (Id) {
    case 0x0004: Algorithm->Size = 20; Algorithm->Bank = EFI_TCG2_BOOT_HASH_ALG_SHA1; break;
    case 0x000B: Algorithm->Size = 32; Algorithm->Bank = EFI_TCG2_BOOT_HASH_ALG_SHA256; break;
    case 0x000C: Algorithm->Size = 48; Algorithm->Bank = EFI_TCG2_BOOT_HASH_ALG_SHA384; break;
    case 0x000D: Algorithm->Size = 64; Algorithm->Bank = EFI_TCG2_BOOT_HASH_ALG_SHA512; break;
    case 0x0012: Algorithm->Size = 32; Algorithm->Bank = EFI_TCG2_BOOT_HASH_ALG_SM3_256; break;
    default: return FALSE;
  }
  return TRUE;
}

STATIC EFI_STATUS
ParseLog (CONST UINT8 *Copy, UINTN LastOffset, UINT32 ActiveBanks, LOG_SUMMARY *Summary)
{
  STATIC CONST CHAR8 SpecSignature[16] = "Spec ID Event03";
  STATIC CONST CHAR8 LocalitySignature[16] = "StartupLocality";
  CONST UINT8 *Bytes;
  CONST UINT8 *Payload;
  CONST UINT8 *Digest;
  UINTN Offset = 0;
  UINTN PayloadOffset;
  UINTN EntryStart;
  UINTN Index;
  UINTN Other;
  UINTN AlgorithmIndex;
  UINT32 EventSize;
  UINT32 Pcr;
  UINT32 Type;
  UINT32 Count;
  UINT32 SeenBanks;
  UINT32 TableBanks = 0;
  UINT16 Id;
  BOOLEAN PcrZeroExtended = FALSE;

  ZeroMem (Summary, sizeof (*Summary));
  Summary->LastOffset = LastOffset;
  if (!Take (Copy, PINNED_LOG_CAPACITY, &Offset, 32, &Bytes) ||
      Little32 (Bytes) != 0 || Little32 (&Bytes[4]) != EV_NO_ACTION ||
      !AllZero (&Bytes[8], 20)) {
    return EFI_COMPROMISED_DATA;
  }
  EventSize = Little32 (&Bytes[28]);
  if (!Take (Copy, PINNED_LOG_CAPACITY, &Offset, EventSize, &Payload) || EventSize < 29 ||
      CompareMem (Payload, SpecSignature, sizeof (SpecSignature)) != 0 ||
      Little32 (&Payload[16]) != 0 || Payload[20] != 0 || Payload[21] != 2 || Payload[23] != 2) {
    return EFI_COMPROMISED_DATA;
  }
  Summary->Errata = Payload[22];
  Count = Little32 (&Payload[24]);
  if (Count == 0 || Count > MAX_ALGORITHMS) {
    return EFI_UNSUPPORTED;
  }
  Summary->AlgorithmCount = Count;
  PayloadOffset = 28;
  for (Index = 0; Index < Count; Index++) {
    if (!Take (Payload, EventSize, &PayloadOffset, 4, &Bytes) ||
        !KnownAlgorithm (Little16 (Bytes), &Summary->Algorithms[Index]) ||
        Little16 (&Bytes[2]) != Summary->Algorithms[Index].Size) {
      return EFI_COMPROMISED_DATA;
    }
    for (Other = 0; Other < Index; Other++) {
      if (Summary->Algorithms[Other].Id == Summary->Algorithms[Index].Id) {
        return EFI_COMPROMISED_DATA;
      }
    }
    TableBanks |= Summary->Algorithms[Index].Bank;
  }
  if (TableBanks != ActiveBanks || (TableBanks & EFI_TCG2_BOOT_HASH_ALG_SHA256) == 0 ||
      !Take (Payload, EventSize, &PayloadOffset, 1, &Bytes)) {
    return EFI_COMPROMISED_DATA;
  }
  Count = Bytes[0];
  if (!Take (Payload, EventSize, &PayloadOffset, Count, &Bytes) || PayloadOffset != EventSize) {
    return EFI_COMPROMISED_DATA;
  }
  Summary->Events = 1;
  if (LastOffset == 0) {
    Summary->Used = Offset;
    return EFI_SUCCESS;
  }
  if (LastOffset < Offset) {
    return EFI_COMPROMISED_DATA;
  }

  for (;;) {
    EntryStart = Offset;
    if (EntryStart > LastOffset || Summary->Events >= MAX_EVENTS ||
        !Take (Copy, PINNED_LOG_CAPACITY, &Offset, 12, &Bytes)) {
      return EFI_COMPROMISED_DATA;
    }
    Pcr = Little32 (Bytes);
    Type = Little32 (&Bytes[4]);
    Count = Little32 (&Bytes[8]);
    if (Pcr >= 24 || Count != Summary->AlgorithmCount || Type == EV_EFI_HCRTM_EVENT) {
      return EFI_UNSUPPORTED;
    }
    SeenBanks = 0;
    for (Index = 0; Index < Count; Index++) {
      if (!Take (Copy, PINNED_LOG_CAPACITY, &Offset, 2, &Bytes)) {
        return EFI_COMPROMISED_DATA;
      }
      Id = Little16 (Bytes);
      for (AlgorithmIndex = 0; AlgorithmIndex < Summary->AlgorithmCount; AlgorithmIndex++) {
        if (Summary->Algorithms[AlgorithmIndex].Id == Id) {
          break;
        }
      }
      if (AlgorithmIndex == Summary->AlgorithmCount ||
          (SeenBanks & Summary->Algorithms[AlgorithmIndex].Bank) != 0 ||
          !Take (Copy, PINNED_LOG_CAPACITY, &Offset,
                 Summary->Algorithms[AlgorithmIndex].Size, &Digest)) {
        return EFI_COMPROMISED_DATA;
      }
      SeenBanks |= Summary->Algorithms[AlgorithmIndex].Bank;
      if (Type == EV_NO_ACTION && !AllZero (Digest, Summary->Algorithms[AlgorithmIndex].Size)) {
        return EFI_COMPROMISED_DATA;
      }
    }
    if (SeenBanks != TableBanks || !Take (Copy, PINNED_LOG_CAPACITY, &Offset, 4, &Bytes)) {
      return EFI_COMPROMISED_DATA;
    }
    EventSize = Little32 (Bytes);
    if (!Take (Copy, PINNED_LOG_CAPACITY, &Offset, EventSize, &Payload)) {
      return EFI_COMPROMISED_DATA;
    }
    if (Type == EV_NO_ACTION && EventSize >= sizeof (LocalitySignature) &&
        CompareMem (Payload, LocalitySignature, sizeof (LocalitySignature)) == 0) {
      if (Pcr != 0 || EventSize != 17 || Summary->LocalityPresent || PcrZeroExtended ||
          (Payload[16] != 0 && Payload[16] != 3)) {
        return EFI_UNSUPPORTED;
      }
      Summary->Locality = Payload[16];
      Summary->LocalityPresent = TRUE;
    }
    if (Type != EV_NO_ACTION && Pcr == 0) {
      PcrZeroExtended = TRUE;
    }
    Summary->Events++;
    if (EntryStart == LastOffset) {
      Summary->Used = Offset;
      return EFI_SUCCESS;
    }
    if (Offset > LastOffset) {
      return EFI_COMPROMISED_DATA;
    }
  }
}

STATIC EFI_STATUS
CopyPermittedLog (EFI_PHYSICAL_ADDRESS Base, EFI_PHYSICAL_ADDRESS Last,
                  VOID *Map, UINT8 *Copy, UINTN *LastOffset)
{
  EFI_STATUS Status;
  EFI_MEMORY_DESCRIPTOR Descriptor;
  UINTN MapSize = MAP_CAPACITY;
  UINTN MapKey;
  UINTN DescriptorSize;
  UINT32 DescriptorVersion;
  UINTN Offset;
  UINT64 Bytes;
  UINT64 End;
  UINT64 LogEnd;
  BOOLEAN Found = FALSE;

  if (Base == 0 || (Base & EFI_PAGE_MASK) != 0 || Base > MAX_UINT64 - PINNED_LOG_CAPACITY ||
      Base > MAX_UINTN || Base + PINNED_LOG_CAPACITY > MAX_UINTN ||
      Last < Base || Last >= Base + PINNED_LOG_CAPACITY) {
    return EFI_COMPROMISED_DATA;
  }
  LogEnd = Base + PINNED_LOG_CAPACITY;
  Status = gBS->GetMemoryMap (&MapSize, Map, &MapKey, &DescriptorSize, &DescriptorVersion);
  if (Status != EFI_SUCCESS) {
    return Status;
  }
  if (MapSize > MAP_CAPACITY || DescriptorSize < sizeof (Descriptor) || DescriptorSize > 256 ||
      DescriptorVersion != EFI_MEMORY_DESCRIPTOR_VERSION || MapSize == 0 ||
      MapSize % DescriptorSize != 0 || MapSize / DescriptorSize > MAX_DESCRIPTORS) {
    return EFI_COMPROMISED_DATA;
  }
  for (Offset = 0; Offset < MapSize; Offset += DescriptorSize) {
    CopyMem (&Descriptor, (CONST UINT8 *)Map + Offset, sizeof (Descriptor));
    if (Descriptor.NumberOfPages == 0 || Descriptor.NumberOfPages > MAX_UINT64 / EFI_PAGE_SIZE ||
        (Descriptor.PhysicalStart & EFI_PAGE_MASK) != 0) {
      return EFI_COMPROMISED_DATA;
    }
    Bytes = Descriptor.NumberOfPages * EFI_PAGE_SIZE;
    if (Descriptor.PhysicalStart > MAX_UINT64 - Bytes) {
      return EFI_COMPROMISED_DATA;
    }
    End = Descriptor.PhysicalStart + Bytes;
    if (Base >= Descriptor.PhysicalStart && LogEnd <= End &&
        (Descriptor.Type == EfiBootServicesData || Descriptor.Type == EfiACPIMemoryNVS) &&
        (Descriptor.Attribute & EFI_MEMORY_RP) == 0) {
      if (Found) {
        return EFI_COMPROMISED_DATA;
      }
      Found = TRUE;
    }
  }
  if (!Found) {
    return EFI_ACCESS_DENIED;
  }
  // The first application dereference of the returned firmware range occurs
  // only after the trusted-provider allocation pin AND the fresh map checks.
  CopyMem (Copy, (CONST VOID *)(UINTN)Base, PINNED_LOG_CAPACITY);
  *LastOffset = (UINTN)(Last - Base);
  return EFI_SUCCESS;
}

STATIC EFI_STATUS
ReadPcrs (EFI_TCG2_PROTOCOL *Tcg2, PCR_SNAPSHOT *Snapshot)
{
  // Public TPM2_PCR_Read: one SHA256 selection, PCR0/2/4/7. No sessions.
  UINT8 Command[20] = {
    0x80, 0x01, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x01, 0x7E,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x0B, 0x03, 0x95, 0x00, 0x00
  };
  UINT8 Response[PCR_RESPONSE_SIZE];
  UINTN Index;
  UINTN Offset;
  EFI_STATUS Status;

  ZeroMem (Response, sizeof (Response));
  ZeroMem (Snapshot, sizeof (*Snapshot));
  Status = Tcg2->SubmitCommand (Tcg2, sizeof (Command), Command, sizeof (Response), Response);
  if (Status != EFI_SUCCESS) {
    return Status;
  }
  if (Big16 (Response) != 0x8001 || Big32 (&Response[2]) != sizeof (Response) ||
      Big32 (&Response[6]) != 0 || Big32 (&Response[14]) != 1 ||
      Big16 (&Response[18]) != 0x000B || Response[20] != 3 ||
      Response[21] != 0x95 || Response[22] != 0 || Response[23] != 0 ||
      Big32 (&Response[24]) != 4) {
    return EFI_COMPROMISED_DATA;
  }
  Snapshot->Counter = Big32 (&Response[10]);
  for (Index = 0; Index < 4; Index++) {
    Offset = 28 + Index * 34;
    if (Big16 (&Response[Offset]) != 32) {
      return EFI_COMPROMISED_DATA;
    }
    CopyMem (Snapshot->Values[Index], &Response[Offset + 2], 32);
  }
  return EFI_SUCCESS;
}

STATIC VOID
Hex32 (CONST UINT8 *Bytes, UINTN Length, CHAR16 *Hex)
{
  STATIC CONST CHAR16 Alphabet[] = L"0123456789abcdef";
  UINTN Index;
  for (Index = 0; Index < Length; Index++) {
    Hex[Index * 2] = Alphabet[Bytes[Index] >> 4];
    Hex[Index * 2 + 1] = Alphabet[Bytes[Index] & 15];
  }
  Hex[Length * 2] = L'\0';
}

STATIC VOID
PrintSnapshot (CHAR16 *Phase, CONST PCR_SNAPSHOT *Snapshot)
{
  STATIC CONST UINT32 PcrIndices[4] = { 0, 2, 4, 7 };
  CHAR16 Hex[65];
  UINTN Index;
  Print (L"\nmvo.tpm-eventlog.counter-%s value=%u\n", Phase, Snapshot->Counter);
  for (Index = 0; Index < 4; Index++) {
    Hex32 (Snapshot->Values[Index], 32, Hex);
    Print (L"\nmvo.tpm-eventlog.pcr-%s index=%u hex=%s\n", Phase, PcrIndices[Index], Hex);
  }
}

EFI_STATUS EFIAPI
UefiMain (EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
{
  EFI_STATUS Status;
  EFI_TCG2_PROTOCOL *Tcg2 = NULL;
  EFI_TCG2_BOOT_SERVICE_CAPABILITY Capability;
  EFI_PHYSICAL_ADDRESS BaseA = 0;
  EFI_PHYSICAL_ADDRESS LastA = 0;
  EFI_PHYSICAL_ADDRESS BaseB = 0;
  EFI_PHYSICAL_ADDRESS LastB = 0;
  BOOLEAN TruncatedA = TRUE;
  BOOLEAN TruncatedB = TRUE;
  UINT8 *CopyA = NULL;
  UINT8 *CopyB = NULL;
  VOID *Map = NULL;
  UINTN LastOffsetA;
  UINTN LastOffsetB;
  LOG_SUMMARY Summary;
  PCR_SNAPSHOT Before;
  PCR_SNAPSHOT After;
  EFI_EVENT CompletionWait = NULL;
  UINTN EventIndex;
  UINTN Offset;
  UINTN ChunkSize;
  CHAR16 Hex[65];
  CHAR16 *Failure = L"initialization";

  (VOID)ImageHandle;
  (VOID)SystemTable;
  Print (L"\nmvo.tpm-eventlog.begin version=1\n");
  Status = gBS->LocateProtocol (&gEfiTcg2ProtocolGuid, NULL, (VOID **)&Tcg2);
  if (Status != EFI_SUCCESS || Tcg2 == NULL) {
    Status = EFI_UNSUPPORTED;
    Failure = L"tcg2-protocol";
    goto Exit;
  }
  ZeroMem (&Capability, sizeof (Capability));
  Capability.Size = (UINT8)sizeof (Capability);
  Status = Tcg2->GetCapability (Tcg2, &Capability);
  if (Status != EFI_SUCCESS || Capability.Size != sizeof (Capability) ||
      Capability.StructureVersion.Major != 1 || Capability.StructureVersion.Minor != 1 ||
      Capability.ProtocolVersion.Major != 1 || Capability.ProtocolVersion.Minor != 1 ||
      !Capability.TPMPresentFlag ||
      (Capability.SupportedEventLogs & EFI_TCG2_EVENT_LOG_FORMAT_TCG_2) == 0 ||
      (Capability.ActivePcrBanks & EFI_TCG2_BOOT_HASH_ALG_SHA256) == 0 ||
      (Capability.ActivePcrBanks & ~Capability.HashAlgorithmBitmap) != 0 ||
      (Capability.ActivePcrBanks & ~0x1FU) != 0 ||
      Capability.MaxCommandSize < 20 || Capability.MaxResponseSize < PCR_RESPONSE_SIZE) {
    Status = EFI_UNSUPPORTED;
    Failure = L"tcg2-capability";
    goto Exit;
  }
  // Complete all owned allocations/events before the bounded capture interval.
  CopyA = AllocatePool (PINNED_LOG_CAPACITY);
  CopyB = AllocatePool (PINNED_LOG_CAPACITY);
  Map = AllocatePool (MAP_CAPACITY);
  if (CopyA == NULL || CopyB == NULL || Map == NULL) {
    Status = EFI_OUT_OF_RESOURCES;
    Failure = L"allocation";
    goto Exit;
  }
  Status = gBS->CreateEvent (EVT_TIMER, TPL_APPLICATION, NULL, NULL, &CompletionWait);
  if (Status == EFI_SUCCESS) {
    Status = gBS->SetTimer (CompletionWait, TimerPeriodic, 10000000ULL);
  }
  if (Status != EFI_SUCCESS) {
    Failure = L"completion-event";
    goto Exit;
  }

  Failure = L"pcr-before";
  Status = ReadPcrs (Tcg2, &Before);
  if (Status != EFI_SUCCESS) { goto Exit; }
  Failure = L"log-before";
  Status = Tcg2->GetEventLog (Tcg2, EFI_TCG2_EVENT_LOG_FORMAT_TCG_2, &BaseA, &LastA, &TruncatedA);
  if (Status != EFI_SUCCESS) { goto Exit; }
  if (TruncatedA) { Status = EFI_VOLUME_FULL; goto Exit; }
  Failure = L"log-memory-before";
  Status = CopyPermittedLog (BaseA, LastA, Map, CopyA, &LastOffsetA);
  if (Status != EFI_SUCCESS) { goto Exit; }
  Failure = L"log-format";
  Status = ParseLog (CopyA, LastOffsetA, Capability.ActivePcrBanks, &Summary);
  if (Status != EFI_SUCCESS) { goto Exit; }

  // Pinned Tcg2Dxe keeps adding to the MAIN log after GetEventLog and also
  // mirrors new events to the final table. Do not append the final table.
  Failure = L"log-after";
  Status = Tcg2->GetEventLog (Tcg2, EFI_TCG2_EVENT_LOG_FORMAT_TCG_2, &BaseB, &LastB, &TruncatedB);
  if (Status != EFI_SUCCESS) { goto Exit; }
  if (TruncatedB || BaseA != BaseB || LastA != LastB) {
    Status = EFI_NOT_READY;
    Failure = L"unstable-snapshot";
    goto Exit;
  }
  Failure = L"log-memory-after";
  Status = CopyPermittedLog (BaseB, LastB, Map, CopyB, &LastOffsetB);
  if (Status != EFI_SUCCESS) { goto Exit; }
  if (LastOffsetA != LastOffsetB || CompareMem (CopyA, CopyB, Summary.Used) != 0) {
    Status = EFI_NOT_READY;
    Failure = L"unstable-snapshot";
    goto Exit;
  }
  Failure = L"pcr-after";
  Status = ReadPcrs (Tcg2, &After);
  if (Status != EFI_SUCCESS) { goto Exit; }
  if (Before.Counter != After.Counter || CompareMem (Before.Values, After.Values, sizeof (Before.Values)) != 0) {
    Status = EFI_NOT_READY;
    Failure = L"unstable-snapshot";
    goto Exit;
  }

  Print (L"\nmvo.tpm-eventlog.snapshot bytes=%u last-offset=%u events=%u locality=%u\n",
         (UINT32)Summary.Used, (UINT32)Summary.LastOffset, Summary.Events, (UINT32)Summary.Locality);
  PrintSnapshot (L"a", &Before);
  PrintSnapshot (L"b", &After);
  for (Offset = 0; Offset < Summary.Used; Offset += ChunkSize) {
    ChunkSize = Summary.Used - Offset;
    if (ChunkSize > 32) { ChunkSize = 32; }
    Hex32 (&CopyA[Offset], ChunkSize, Hex);
    Print (L"\nmvo.tpm-eventlog.data offset=%u hex=%s\n", (UINT32)Offset, Hex);
  }
  Print (L"\nmvo.tpm-eventlog.complete bytes=%u chunks=%u events=%u locality=%u\n",
         (UINT32)Summary.Used, (UINT32)((Summary.Used + 31) / 32), Summary.Events, (UINT32)Summary.Locality);
  // Stay in this image. The fixture owner will perform acknowledged QMP quit.
  // No image load, ExitBootServices, PCR extend/reset, or NV/variable operation.
  for (;;) {
    Status = gBS->WaitForEvent (1, &CompletionWait, &EventIndex);
    if (Status != EFI_SUCCESS || EventIndex != 0) {
      if (Status == EFI_SUCCESS) { Status = EFI_COMPROMISED_DATA; }
      Failure = L"completion-wait";
      goto Exit;
    }
  }

Exit:
  Print (L"\nmvo.tpm-eventlog.failure stage=%s status=%r\n", Failure, Status);
  if (CompletionWait != NULL) { gBS->CloseEvent (CompletionWait); }
  if (Map != NULL) { FreePool (Map); }
  if (CopyB != NULL) { FreePool (CopyB); }
  if (CopyA != NULL) { FreePool (CopyA); }
  return Status;
}
