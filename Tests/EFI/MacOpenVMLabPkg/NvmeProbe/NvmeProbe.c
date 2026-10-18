// SPDX-License-Identifier: Apache-2.0
// Original bounded NVMe sector probe for one fresh 32 MiB no-OS fixture.
#include <Uefi.h>
#include <Guid/FileInfo.h>
#include <Protocol/BlockIo.h>
#include <Protocol/DevicePath.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiLib.h>

#if defined (MVO_NVME_PREPARE) == defined (MVO_NVME_VERIFY_ONLY)
#error Select exactly one explicit prepare or verification build.
#endif
#if defined (MVO_NVME_PREPARE) && MVO_NVME_PREPARE != 1
#error The prepare build must use MVO_NVME_PREPARE=1.
#endif
#if defined (MVO_NVME_VERIFY_ONLY) && MVO_NVME_VERIFY_ONLY != 1
#error The verification build must use MVO_NVME_VERIFY_ONLY=1.
#endif

#define FIXTURE_BYTES          64U
#define SECTOR_BYTES           512U
#define REQUIRED_LAST_BLOCK    65535ULL
#define MAX_HANDLES            128U
#define MAX_PATH_BYTES         1024U
#define MAX_PATH_NODES         64U
#define MAX_IO_ALIGN           4096U

#if defined (MVO_NVME_PREPARE)
STATIC CONST CHAR8 mPhase[] = "prepare";
#else
STATIC CONST CHAR8 mPhase[] = "verify";
#endif
STATIC CONST UINT8 mFixtureMagic[8] = { 'M', 'V', 'O', 'N', 'V', 'M', 'E', '1' };
STATIC CONST UINT8 mSectorMagic[8] = { 'M', 'V', 'O', 'N', 'V', 'S', 'E', 'C' };
STATIC CONST EFI_LBA mLbas[3] = { 8, 32768, 65535 };
STATIC UINT32 mReads;
STATIC UINT32 mWrites;
STATIC UINT32 mFlushes;

STATIC BOOLEAN
AllZero (CONST UINT8 *Bytes, UINTN Count)
{
  UINTN Index;
  for (Index = 0; Index < Count; Index++) {
    if (Bytes[Index] != 0) {
      return FALSE;
    }
  }
  return TRUE;
}

STATIC UINT32
ReadLe32 (CONST UINT8 *Bytes)
{
  return (UINT32)Bytes[0] | ((UINT32)Bytes[1] << 8) |
         ((UINT32)Bytes[2] << 16) | ((UINT32)Bytes[3] << 24);
}

// Exact own-media file: magic[8], probeID[16], raw big-endian EUI64[8], nonce[32].
// The probe never searches other file systems or accepts a caller-supplied path.
STATIC EFI_STATUS
ReadFixture (EFI_HANDLE ImageHandle, UINT8 Fixture[FIXTURE_BYTES])
{
  EFI_LOADED_IMAGE_PROTOCOL *Image = NULL;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *Fs = NULL;
  EFI_FILE_PROTOCOL *Root = NULL;
  EFI_FILE_PROTOCOL *File = NULL;
  union {
    EFI_FILE_INFO Align;
    UINT8 Bytes[512];
  } Info;
  UINT8 Bytes[FIXTURE_BYTES + 1];
  UINT8 Extra;
  UINTN InfoSize = sizeof (Info);
  UINTN Size = sizeof (Bytes);
  UINTN ExtraSize = sizeof (Extra);
  EFI_STATUS Status;
  EFI_STATUS CloseStatus;

  Status = gBS->HandleProtocol (ImageHandle, &gEfiLoadedImageProtocolGuid, (VOID **)&Image);
  if (EFI_ERROR (Status) || Image == NULL || Image->DeviceHandle == NULL) {
    return EFI_NOT_FOUND;
  }
  Status = gBS->HandleProtocol (Image->DeviceHandle, &gEfiSimpleFileSystemProtocolGuid, (VOID **)&Fs);
  if (EFI_ERROR (Status) || Fs == NULL || Fs->OpenVolume == NULL) {
    return EFI_NOT_FOUND;
  }
  Status = Fs->OpenVolume (Fs, &Root);
  if (EFI_ERROR (Status) || Root == NULL) {
    return EFI_NOT_FOUND;
  }
  if (Root->Close == NULL) {
    return EFI_COMPROMISED_DATA;
  }
  if (Root->Open == NULL) {
    Status = EFI_COMPROMISED_DATA;
    goto CloseRoot;
  }
  Status = Root->Open (Root, &File, L"\\MVO-NVME-DATA.BIN", EFI_FILE_MODE_READ, 0);
  if (EFI_ERROR (Status) || File == NULL) {
    if (!EFI_ERROR (Status)) {
      Status = EFI_COMPROMISED_DATA;
    }
    goto CloseRoot;
  }
  if (File->GetInfo == NULL || File->Read == NULL || File->Close == NULL) {
    Status = EFI_COMPROMISED_DATA;
    goto CloseFile;
  }
  ZeroMem (&Info, sizeof (Info));
  Status = File->GetInfo (File, &gEfiFileInfoGuid, &InfoSize, &Info);
  if (EFI_ERROR (Status)) {
    goto CloseFile;
  }
  if (InfoSize < SIZE_OF_EFI_FILE_INFO + sizeof (CHAR16) || InfoSize > sizeof (Info) ||
      Info.Align.Size != InfoSize || Info.Align.FileSize != FIXTURE_BYTES ||
      (Info.Align.Attribute & EFI_FILE_DIRECTORY) != 0 ||
      (Info.Align.Attribute & ~((UINT64)EFI_FILE_VALID_ATTR)) != 0) {
    Status = EFI_COMPROMISED_DATA;
    goto CloseFile;
  }
  ZeroMem (Bytes, sizeof (Bytes));
  Status = File->Read (File, &Size, Bytes);
  if (!EFI_ERROR (Status) && Size != FIXTURE_BYTES) {
    Status = EFI_COMPROMISED_DATA;
  }
  if (!EFI_ERROR (Status)) {
    Status = File->Read (File, &ExtraSize, &Extra);
    if (!EFI_ERROR (Status) && ExtraSize != 0) {
      Status = EFI_COMPROMISED_DATA;
    }
  }
CloseFile:
  if (File->Close != NULL) {
    CloseStatus = File->Close (File);
    if (!EFI_ERROR (Status) && EFI_ERROR (CloseStatus)) {
      Status = CloseStatus;
    }
  }
CloseRoot:
  CloseStatus = Root->Close (Root);
  if (!EFI_ERROR (Status) && EFI_ERROR (CloseStatus)) {
    Status = CloseStatus;
  }
  if (EFI_ERROR (Status)) {
    return Status;
  }
  if (CompareMem (Bytes, mFixtureMagic, sizeof (mFixtureMagic)) != 0 ||
      AllZero (Bytes + 8, 16) || AllZero (Bytes + 24, 8) || AllZero (Bytes + 32, 32)) {
    return EFI_COMPROMISED_DATA;
  }
  CopyMem (Fixture, Bytes, FIXTURE_BYTES);
  return EFI_SUCCESS;
}

// Device paths are protocol-owned packed bytes. Bounds precede every field read;
// NamespaceUuid is compared as raw bytes, never as a native UINT64 on AArch64.
STATIC EFI_STATUS
PathMatches (EFI_DEVICE_PATH_PROTOCOL *Path, CONST UINT8 Eui64[8], BOOLEAN *Match)
{
  CONST UINT8 *Bytes = (CONST UINT8 *)Path;
  UINTN Offset = 0;
  UINTN Nodes;
  UINTN Length;
  UINTN Namespaces = 0;
  BOOLEAN Found = FALSE;
  BOOLEAN Partition = FALSE;
  UINT8 Type;
  UINT8 SubType;

  *Match = FALSE;
  if (Path == NULL) {
    return EFI_NOT_FOUND;
  }
  for (Nodes = 0; Nodes < MAX_PATH_NODES; Nodes++) {
    if (Offset > MAX_PATH_BYTES - 4) {
      return EFI_COMPROMISED_DATA;
    }
    Type = Bytes[Offset];
    SubType = Bytes[Offset + 1];
    Length = (UINTN)Bytes[Offset + 2] | ((UINTN)Bytes[Offset + 3] << 8);
    if (Length < 4 || Length > MAX_PATH_BYTES - Offset) {
      return EFI_COMPROMISED_DATA;
    }
    if (Type == END_DEVICE_PATH_TYPE) {
      if (SubType != END_ENTIRE_DEVICE_PATH_SUBTYPE || Length != 4) {
        return EFI_COMPROMISED_DATA;
      }
      *Match = Namespaces == 1 && Found && !Partition;
      return EFI_SUCCESS;
    }
    if (Type < HARDWARE_DEVICE_PATH || Type > BBS_DEVICE_PATH) {
      return EFI_UNSUPPORTED;
    }
    if (Type == MEDIA_DEVICE_PATH) {
      Partition = TRUE;
    }
    if (Type == MESSAGING_DEVICE_PATH && SubType == MSG_NVME_NAMESPACE_DP) {
      if (Length != 16 || ++Namespaces != 1) {
        return EFI_COMPROMISED_DATA;
      }
      Found = ReadLe32 (Bytes + Offset + 4) == 1 &&
              CompareMem (Bytes + Offset + 8, Eui64, 8) == 0;
    }
    Offset += Length;
  }
  return EFI_COMPROMISED_DATA;
}

STATIC EFI_STATUS
MediaValid (EFI_BLOCK_IO_PROTOCOL *Block)
{
  EFI_BLOCK_IO_MEDIA *Media;
  UINT32 Align;

  if (Block == NULL || Block->Revision < EFI_BLOCK_IO_PROTOCOL_REVISION ||
      Block->Media == NULL || Block->ReadBlocks == NULL) {
    return EFI_COMPROMISED_DATA;
  }
  Media = Block->Media;
  Align = Media->IoAlign;
  if (!Media->MediaPresent || Media->LogicalPartition || Media->ReadOnly || Media->RemovableMedia ||
      Media->BlockSize != SECTOR_BYTES || Media->LastBlock != REQUIRED_LAST_BLOCK ||
      Align > MAX_IO_ALIGN || (Align > 1 && (Align & (Align - 1)) != 0)) {
    return EFI_UNSUPPORTED;
  }
#if defined (MVO_NVME_PREPARE)
  if (Block->WriteBlocks == NULL || Block->FlushBlocks == NULL) {
    return EFI_COMPROMISED_DATA;
  }
#endif
  return EFI_SUCCESS;
}

STATIC EFI_STATUS
SelectTarget (CONST UINT8 Fixture[FIXTURE_BYTES], EFI_HANDLE *Handle, EFI_BLOCK_IO_PROTOCOL **Block)
{
  EFI_HANDLE Handles[MAX_HANDLES];
  UINTN Size = sizeof (Handles);
  UINTN Index;
  UINTN Matches = 0;
  EFI_DEVICE_PATH_PROTOCOL *Path;
  EFI_BLOCK_IO_PROTOCOL *Candidate;
  BOOLEAN Match;
  EFI_STATUS Status;

  *Handle = NULL;
  *Block = NULL;
  Status = gBS->LocateHandle (ByProtocol, &gEfiBlockIoProtocolGuid, NULL, &Size, Handles);
  if (EFI_ERROR (Status)) {
    return Status;
  }
  if (Size == 0 || Size > sizeof (Handles) || Size % sizeof (EFI_HANDLE) != 0) {
    return EFI_COMPROMISED_DATA;
  }
  for (Index = 0; Index < Size / sizeof (EFI_HANDLE); Index++) {
    Path = NULL;
    Status = gBS->HandleProtocol (Handles[Index], &gEfiDevicePathProtocolGuid, (VOID **)&Path);
    if (EFI_ERROR (Status) || Path == NULL) {
      continue;
    }
    Status = PathMatches (Path, Fixture + 24, &Match);
    if (EFI_ERROR (Status)) {
      return Status;
    }
    if (!Match) {
      continue;
    }
    if (++Matches != 1) {
      return EFI_COMPROMISED_DATA;
    }
    Candidate = NULL;
    Status = gBS->HandleProtocol (Handles[Index], &gEfiBlockIoProtocolGuid, (VOID **)&Candidate);
    if (EFI_ERROR (Status)) {
      return Status;
    }
    Status = MediaValid (Candidate);
    if (EFI_ERROR (Status)) {
      return Status;
    }
    *Handle = Handles[Index];
    *Block = Candidate;
  }
  return Matches == 1 ? EFI_SUCCESS : EFI_NOT_FOUND;
}

STATIC EFI_STATUS
Revalidate (EFI_HANDLE Handle, EFI_BLOCK_IO_PROTOCOL *Block, CONST UINT8 Fixture[FIXTURE_BYTES],
            UINT32 MediaId, UINT32 IoAlign)
{
  EFI_DEVICE_PATH_PROTOCOL *Path = NULL;
  EFI_BLOCK_IO_PROTOCOL *Current = NULL;
  BOOLEAN Match;
  EFI_STATUS Status;

  Status = gBS->HandleProtocol (Handle, &gEfiBlockIoProtocolGuid, (VOID **)&Current);
  if (EFI_ERROR (Status) || Current != Block) {
    return EFI_MEDIA_CHANGED;
  }
  Status = MediaValid (Block);
  if (EFI_ERROR (Status)) {
    return Status;
  }
  if (Block->Media->MediaId != MediaId || Block->Media->IoAlign != IoAlign) {
    return EFI_MEDIA_CHANGED;
  }
  Status = gBS->HandleProtocol (Handle, &gEfiDevicePathProtocolGuid, (VOID **)&Path);
  if (EFI_ERROR (Status)) {
    return Status;
  }
  Status = PathMatches (Path, Fixture + 24, &Match);
  return EFI_ERROR (Status) ? Status : (Match ? EFI_SUCCESS : EFI_MEDIA_CHANGED);
}

STATIC EFI_STATUS
AlignedSector (UINT32 IoAlign, VOID **Allocation, UINT8 **Buffer)
{
  UINTN Alignment = IoAlign > 1 ? IoAlign : 1;
  UINTN Bytes = SECTOR_BYTES + Alignment - 1;
  UINTN Address;

  *Allocation = NULL;
  *Buffer = NULL;
  if (IoAlign > MAX_IO_ALIGN || (IoAlign > 1 && (IoAlign & (IoAlign - 1)) != 0)) {
    return EFI_INVALID_PARAMETER;
  }
  *Allocation = AllocatePool (Bytes);
  if (*Allocation == NULL) {
    return EFI_OUT_OF_RESOURCES;
  }
  if ((UINTN)*Allocation > MAX_UINTN - (Alignment - 1)) {
    FreePool (*Allocation);
    *Allocation = NULL;
    return EFI_OUT_OF_RESOURCES;
  }
  Address = ((UINTN)*Allocation + Alignment - 1) & ~(Alignment - 1);
  if (Address - (UINTN)*Allocation > Bytes - SECTOR_BYTES) {
    FreePool (*Allocation);
    *Allocation = NULL;
    return EFI_COMPROMISED_DATA;
  }
  *Buffer = (UINT8 *)Address;
  return EFI_SUCCESS;
}

STATIC VOID
Pattern (CONST UINT8 Fixture[FIXTURE_BYTES], EFI_LBA Lba, UINT8 Buffer[SECTOR_BYTES])
{
  UINTN Index;
  CopyMem (Buffer, mSectorMagic, sizeof (mSectorMagic));
  CopyMem (Buffer + 8, Fixture + 8, FIXTURE_BYTES - 8);
  for (Index = 0; Index < 8; Index++) {
    Buffer[64 + Index] = (UINT8)(Lba >> (8 * Index));
  }
  for (Index = 72; Index < SECTOR_BYTES; Index++) {
    Buffer[Index] = Fixture[32 + (Index - 72) % 32] ^ Fixture[8 + (Index - 72) % 16] ^
                    (UINT8)(Lba >> (8 * ((Index - 72) % 8))) ^ (UINT8)Index;
  }
}

// No addition of Lba+Count is used. Only the three compile-time single sectors
// can reach BlockIO, and the current media is checked before and after each read.
STATIC BOOLEAN
SectorAllowed (EFI_LBA Lba, EFI_LBA LastBlock, UINTN Count)
{
  return Count == 1 && (Lba == 8 || Lba == 32768 || Lba == 65535) &&
         Lba <= LastBlock && Count - 1 <= LastBlock - Lba;
}

STATIC EFI_STATUS
ReadSector (EFI_HANDLE Handle, EFI_BLOCK_IO_PROTOCOL *Block, CONST UINT8 Fixture[FIXTURE_BYTES],
            UINT32 MediaId, UINT32 IoAlign, EFI_LBA Lba, UINT8 Buffer[SECTOR_BYTES])
{
  EFI_STATUS Status = Revalidate (Handle, Block, Fixture, MediaId, IoAlign);
  if (EFI_ERROR (Status)) {
    return Status;
  }
  if (!SectorAllowed (Lba, Block->Media->LastBlock, 1)) {
    return EFI_INVALID_PARAMETER;
  }
  ZeroMem (Buffer, SECTOR_BYTES);
  mReads++;
  Status = Block->ReadBlocks (Block, MediaId, Lba, SECTOR_BYTES, Buffer);
  return EFI_ERROR (Status) ? Status : Revalidate (Handle, Block, Fixture, MediaId, IoAlign);
}

STATIC VOID
Hold (VOID)
{
  EFI_EVENT Event = NULL;
  UINTN Index;
  EFI_STATUS Status;
  Status = gBS->CreateEvent (EVT_TIMER, TPL_APPLICATION, NULL, NULL, &Event);
  if (!EFI_ERROR (Status)) {
    Status = gBS->SetTimer (Event, TimerPeriodic, 10000000);
    if (EFI_ERROR (Status)) {
      gBS->CloseEvent (Event);
      Event = NULL;
    }
  } else {
    Event = NULL;
  }
  for (;;) {
    if (Event != NULL) {
      Status = gBS->WaitForEvent (1, &Event, &Index);
      if (!EFI_ERROR (Status) && Index == 0) {
        continue;
      }
      gBS->CloseEvent (Event);
      Event = NULL;
    }
    gBS->Stall (1000000);
  }
}

EFI_STATUS EFIAPI
UefiMain (EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
{
  UINT8 Fixture[FIXTURE_BYTES];
  EFI_HANDLE Handle = NULL;
  EFI_BLOCK_IO_PROTOCOL *Block = NULL;
  VOID *ReadAllocation = NULL;
  VOID *PatternAllocation = NULL;
  UINT8 *ReadBuffer = NULL;
  UINT8 *PatternBuffer = NULL;
  UINT32 MediaId;
  UINT32 IoAlign;
  UINTN Index;
  EFI_STATUS Status;
  CONST CHAR8 *Stage = "architecture";

  (VOID)SystemTable;
  Print (L"\nmvo.nvme-probe.begin version=1 phase=%a\n", mPhase);
#if !defined (MDE_CPU_AARCH64)
  Status = EFI_UNSUPPORTED;
  goto Failed;
#endif
  Stage = "fixture";
  Status = ReadFixture (ImageHandle, Fixture);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Print (L"mvo.nvme-probe.fixture bytes=64\n");
  Stage = "namespace";
  Status = SelectTarget (Fixture, &Handle, &Block);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  MediaId = Block->Media->MediaId;
  IoAlign = Block->Media->IoAlign;
  Print (L"mvo.nvme-probe.namespace nsid=1 block-size=512 last-block=65535 io-align=%u matches=1\n", IoAlign);
  Stage = "aligned-buffers";
  Status = AlignedSector (IoAlign, &ReadAllocation, &ReadBuffer);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Status = AlignedSector (IoAlign, &PatternAllocation, &PatternBuffer);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
#if defined (MVO_NVME_PREPARE)
  // Establish every selected sector is fresh before the first mutation.
  Stage = "fresh-sectors";
  for (Index = 0; Index < 3; Index++) {
    Status = ReadSector (Handle, Block, Fixture, MediaId, IoAlign, mLbas[Index], ReadBuffer);
    if (EFI_ERROR (Status) || !AllZero (ReadBuffer, SECTOR_BYTES)) {
      if (!EFI_ERROR (Status)) {
        Status = EFI_COMPROMISED_DATA;
      }
      goto Failed;
    }
    Print (L"mvo.nvme-probe.zero lba=%u matched=1\n", (UINT32)mLbas[Index]);
  }
  Stage = "write-sectors";
  for (Index = 0; Index < 3; Index++) {
    Status = Revalidate (Handle, Block, Fixture, MediaId, IoAlign);
    if (EFI_ERROR (Status)) {
      goto Failed;
    }
    if (!SectorAllowed (mLbas[Index], Block->Media->LastBlock, 1)) {
      Status = EFI_INVALID_PARAMETER;
      goto Failed;
    }
    Pattern (Fixture, mLbas[Index], PatternBuffer);
    mWrites++;
    Status = Block->WriteBlocks (Block, MediaId, mLbas[Index], SECTOR_BYTES, PatternBuffer);
    if (!EFI_ERROR (Status)) {
      Status = Revalidate (Handle, Block, Fixture, MediaId, IoAlign);
    }
    if (EFI_ERROR (Status)) {
      goto Failed;
    }
    Print (L"mvo.nvme-probe.write lba=%u bytes=512\n", (UINT32)mLbas[Index]);
  }
  Stage = "flush";
  Status = Revalidate (Handle, Block, Fixture, MediaId, IoAlign);
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  mFlushes++;
  Status = Block->FlushBlocks (Block);
  if (!EFI_ERROR (Status)) {
    Status = Revalidate (Handle, Block, Fixture, MediaId, IoAlign);
  }
  if (EFI_ERROR (Status)) {
    goto Failed;
  }
  Print (L"mvo.nvme-probe.flush count=1\n");
#endif
  Stage = "read-compare";
  for (Index = 0; Index < 3; Index++) {
    Pattern (Fixture, mLbas[Index], PatternBuffer);
    Status = ReadSector (Handle, Block, Fixture, MediaId, IoAlign, mLbas[Index], ReadBuffer);
    if (EFI_ERROR (Status) || CompareMem (ReadBuffer, PatternBuffer, SECTOR_BYTES) != 0) {
      if (!EFI_ERROR (Status)) {
        Status = EFI_CRC_ERROR;
      }
      goto Failed;
    }
    Print (L"mvo.nvme-probe.readback phase=%a lba=%u matched=1\n", mPhase, (UINT32)mLbas[Index]);
  }
  FreePool (ReadAllocation);
  FreePool (PatternAllocation);
  Print (L"mvo.nvme-probe.complete phase=%a sectors=3 reads=%u writes=%u flushes=%u\n",
         mPhase, mReads, mWrites, mFlushes);
  Hold ();
  return EFI_SUCCESS;
Failed:
  if (ReadAllocation != NULL) {
    FreePool (ReadAllocation);
  }
  if (PatternAllocation != NULL) {
    FreePool (PatternAllocation);
  }
  Print (L"\nmvo.nvme-probe.failure phase=%a stage=%a status=0x%016lx\n", mPhase, Stage, (UINT64)Status);
  Hold ();
  return Status;
}
