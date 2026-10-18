// SPDX-License-Identifier: Apache-2.0
// Original bounded GOP and synthetic-key acknowledgement probe for a no-OS lab.
#include <Uefi.h>
#include <Protocol/GraphicsOutput.h>
#include <Library/BaseMemoryLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiLib.h>

#define MIN_DIMENSION       64U
#define MAX_DIMENSION       4096U
#define MAX_STRIDE          8192U
#define MAX_FRAMEBUFFER     (128ULL * 1024ULL * 1024ULL)
#define MAX_MODE_ENUMERATION 64U
#define KEY_TIMEOUT         150000000ULL

STATIC BOOLEAN
ValidModeInfo (CONST EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info, UINTN Size)
{
  if (Info == NULL || Size < sizeof (*Info) || Size > 256 || Info->Version != 0 ||
      Info->HorizontalResolution < MIN_DIMENSION || Info->HorizontalResolution > MAX_DIMENSION ||
      Info->VerticalResolution < MIN_DIMENSION || Info->VerticalResolution > MAX_DIMENSION ||
      Info->PixelsPerScanLine < Info->HorizontalResolution || Info->PixelsPerScanLine > MAX_STRIDE) {
    return FALSE;
  }
  return Info->PixelFormat == PixelRedGreenBlueReserved8BitPerColor ||
         Info->PixelFormat == PixelBlueGreenRedReserved8BitPerColor;
}

STATIC EFI_STATUS
ReadAppliedMode (EFI_GRAPHICS_OUTPUT_PROTOCOL *Gop, EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info,
                 UINT32 *ModeNumber)
{
  UINT64 Required;

  if (Gop == NULL || Gop->Mode == NULL || Gop->Mode->MaxMode == 0 ||
      Gop->Mode->Mode >= Gop->Mode->MaxMode ||
      !ValidModeInfo (Gop->Mode->Info, Gop->Mode->SizeOfInfo)) {
    return EFI_COMPROMISED_DATA;
  }
  Required = (UINT64)Gop->Mode->Info->PixelsPerScanLine *
             (UINT64)Gop->Mode->Info->VerticalResolution * 4;
  if (Required == 0 || Required > MAX_FRAMEBUFFER || Gop->Mode->FrameBufferBase == 0 ||
      Gop->Mode->FrameBufferSize < Required || Gop->Mode->FrameBufferSize > MAX_FRAMEBUFFER ||
      Gop->Mode->FrameBufferBase > MAX_UINT64 - (UINT64)Gop->Mode->FrameBufferSize) {
    return EFI_COMPROMISED_DATA;
  }
  CopyMem (Info, Gop->Mode->Info, sizeof (*Info));
  *ModeNumber = Gop->Mode->Mode;
  return EFI_SUCCESS;
}

STATIC EFI_STATUS
FindDifferentMode (EFI_GRAPHICS_OUTPUT_PROTOCOL *Gop,
                   CONST EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Current, UINT32 CurrentNumber,
                   EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Selected, UINT32 *SelectedNumber)
{
  EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info;
  UINTN Size;
  UINT32 Number;
  UINT32 Count = Gop->Mode->MaxMode;
  EFI_STATUS Status;

  if (Count > MAX_MODE_ENUMERATION) {
    Count = MAX_MODE_ENUMERATION;
  }
  for (Number = 0; Number < Count; Number++) {
    Info = NULL;
    Size = 0;
    Status = Gop->QueryMode (Gop, Number, &Size, &Info);
    if (Status == EFI_SUCCESS && Number != CurrentNumber && ValidModeInfo (Info, Size) &&
        (Info->HorizontalResolution != Current->HorizontalResolution ||
         Info->VerticalResolution != Current->VerticalResolution)) {
      CopyMem (Selected, Info, sizeof (*Selected));
      *SelectedNumber = Number;
      FreePool (Info);
      return EFI_SUCCESS;
    }
    if (Info != NULL) {
      FreePool (Info);
    }
  }
  return EFI_UNSUPPORTED;
}

STATIC EFI_STATUS
DrawQuadrants (EFI_GRAPHICS_OUTPUT_PROTOCOL *Gop,
               CONST EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info, UINT32 Stage)
{
  // EFI BLT pixels are Blue, Green, Red, Reserved. The semantic RGB palette is
  // (240,32,16), (32,224,64), (16,64,240), (224,192,32).
  STATIC CONST EFI_GRAPHICS_OUTPUT_BLT_PIXEL Palette[4] = {
    { 16, 32, 240, 0 }, { 64, 224, 32, 0 }, { 240, 64, 16, 0 }, { 32, 192, 224, 0 }
  };
  EFI_GRAPHICS_OUTPUT_BLT_PIXEL Pixel;
  UINTN Left = Info->HorizontalResolution / 2;
  UINTN Top = Info->VerticalResolution / 2;
  UINTN X;
  UINTN Y;
  UINTN Width;
  UINTN Height;
  UINT32 Quadrant;
  EFI_STATUS Status;

  if (gST->ConOut == NULL) {
    return EFI_UNSUPPORTED;
  }
  Status = gST->ConOut->SetCursorPosition (gST->ConOut, 0, 0);
  if (Status != EFI_SUCCESS) {
    return Status;
  }
  for (Quadrant = 0; Quadrant < 4; Quadrant++) {
    X = (Quadrant & 1) != 0 ? Left : 0;
    Y = (Quadrant & 2) != 0 ? Top : 0;
    Width = (Quadrant & 1) != 0 ? Info->HorizontalResolution - Left : Left;
    Height = (Quadrant & 2) != 0 ? Info->VerticalResolution - Top : Top;
    CopyMem (&Pixel, &Palette[(Quadrant + Stage) % 4], sizeof (Pixel));
    Status = Gop->Blt (Gop, &Pixel, EfiBltVideoFill, 0, 0, X, Y, Width, Height, 0);
    if (Status != EFI_SUCCESS) {
      return Status;
    }
  }
  return EFI_SUCCESS;
}

STATIC EFI_STATUS
ReadExpectedKey (CHAR16 Expected, EFI_INPUT_KEY *Received)
{
  EFI_EVENT Deadline = NULL;
  EFI_EVENT Events[2];
  UINTN EventIndex;
  EFI_STATUS Status;

  if (gST->ConIn == NULL || gST->ConIn->WaitForKey == NULL) {
    return EFI_UNSUPPORTED;
  }
  Status = gBS->CreateEvent (EVT_TIMER, TPL_APPLICATION, NULL, NULL, &Deadline);
  if (Status != EFI_SUCCESS) {
    return Status;
  }
  Status = gBS->SetTimer (Deadline, TimerRelative, KEY_TIMEOUT);
  if (Status != EFI_SUCCESS) {
    gBS->CloseEvent (Deadline);
    return Status;
  }
  Events[0] = gST->ConIn->WaitForKey;
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
    Status = gST->ConIn->ReadKeyStroke (gST->ConIn, Received);
    if (Status == EFI_SUCCESS) {
      if (Received->ScanCode != 0 || Received->UnicodeChar != Expected) {
        Status = EFI_COMPROMISED_DATA;
      }
      break;
    }
    if (Status != EFI_NOT_READY) {
      break;
    }
    Status = gBS->WaitForEvent (2, Events, &EventIndex);
    if (Status != EFI_SUCCESS) {
      break;
    }
    if (EventIndex == 1) {
      Status = EFI_TIMEOUT;
      break;
    }
    if (EventIndex != 0) {
      Status = EFI_COMPROMISED_DATA;
      break;
    }
  }
  gBS->SetTimer (Deadline, TimerCancel, 0);
  gBS->CloseEvent (Deadline);
  return Status;
}

EFI_STATUS EFIAPI
UefiMain (EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
{
  EFI_GRAPHICS_OUTPUT_PROTOCOL *Gop = NULL;
  EFI_GRAPHICS_OUTPUT_MODE_INFORMATION Original;
  EFI_GRAPHICS_OUTPUT_MODE_INFORMATION Selected;
  EFI_GRAPHICS_OUTPUT_MODE_INFORMATION Applied;
  UINT32 OriginalNumber;
  UINT32 SelectedNumber;
  UINT32 AppliedNumber;
  EFI_INPUT_KEY Key;
  STATIC CONST CHAR16 Sequence[8] = { L'1', L'1', L'2', L'2', L'1', L'1', L'2', L'2' };
  UINT32 Index;
  EFI_EVENT CompletionEvent = NULL;
  UINTN EventIndex;
  EFI_STATUS Status;
  CONST CHAR8 *Stage = "architecture";

  (VOID)ImageHandle;
  (VOID)SystemTable;
  Print (L"\nmvo.display-input.begin version=1\n");
#if !defined (MDE_CPU_AARCH64)
  Status = EFI_UNSUPPORTED;
  goto Failed;
#endif
  Stage = "gop-protocol";
  Status = gBS->LocateProtocol (&gEfiGraphicsOutputProtocolGuid, NULL, (VOID **)&Gop);
  if (Status != EFI_SUCCESS || Gop == NULL) {
    if (Status == EFI_SUCCESS) {
      Status = EFI_UNSUPPORTED;
    }
    goto Failed;
  }
  Stage = "current-mode";
  Status = ReadAppliedMode (Gop, &Original, &OriginalNumber);
  if (Status != EFI_SUCCESS) {
    goto Failed;
  }
  Stage = "different-mode";
  Status = FindDifferentMode (Gop, &Original, OriginalNumber, &Selected, &SelectedNumber);
  if (Status != EFI_SUCCESS) {
    goto Failed;
  }
  Stage = "reset-input";
  if (gST->ConIn == NULL) {
    Status = EFI_UNSUPPORTED;
    goto Failed;
  }
  Status = gST->ConIn->Reset (gST->ConIn, FALSE);
  if (Status != EFI_SUCCESS) {
    goto Failed;
  }
  Stage = "draw-stage0";
  Status = DrawQuadrants (Gop, &Original, 0);
  if (Status != EFI_SUCCESS) {
    goto Failed;
  }
  Print (L"\nmvo.display-input.ready stage=0 width=%u height=%u mode=%u\n",
         Original.HorizontalResolution, Original.VerticalResolution, OriginalNumber);
  Stage = "stage0-key";
  Status = ReadExpectedKey (L'1', &Key);
  if (Status != EFI_SUCCESS) {
    goto Failed;
  }
  Print (L"mvo.display-input.ack stage=0 key=1\n");
  Stage = "set-second-mode";
  Status = Gop->SetMode (Gop, SelectedNumber);
  if (Status != EFI_SUCCESS) {
    goto Failed;
  }
  Stage = "applied-second-mode";
  Status = ReadAppliedMode (Gop, &Applied, &AppliedNumber);
  if (Status != EFI_SUCCESS) {
    goto Failed;
  }
  if (AppliedNumber != SelectedNumber || Applied.HorizontalResolution != Selected.HorizontalResolution ||
      Applied.VerticalResolution != Selected.VerticalResolution || Applied.PixelFormat != Selected.PixelFormat ||
      Applied.PixelsPerScanLine != Selected.PixelsPerScanLine) {
    Status = EFI_COMPROMISED_DATA;
    goto Failed;
  }
  Stage = "draw-stage1";
  Status = DrawQuadrants (Gop, &Applied, 1);
  if (Status != EFI_SUCCESS) {
    goto Failed;
  }
  Print (L"\nmvo.display-input.ready stage=1 width=%u height=%u mode=%u\n",
         Applied.HorizontalResolution, Applied.VerticalResolution, AppliedNumber);
  Stage = "stage1-key";
  Status = ReadExpectedKey (L'2', &Key);
  if (Status != EFI_SUCCESS) {
    goto Failed;
  }
  Print (L"mvo.display-input.ack stage=1 key=2\n");
  Stage = "repeated-keys";
  for (Index = 0; Index < ARRAY_SIZE (Sequence); Index++) {
    Print (L"mvo.display-input.key-ready index=%u\n", Index);
    Status = ReadExpectedKey (Sequence[Index], &Key);
    if (Status != EFI_SUCCESS) {
      goto Failed;
    }
    Print (L"mvo.display-input.key-ack index=%u unicode=%u scan=0\n", Index, (UINT32)Key.UnicodeChar);
  }
  Stage = "completion-event";
  Status = gBS->CreateEvent (EVT_TIMER, TPL_APPLICATION, NULL, NULL, &CompletionEvent);
  if (Status != EFI_SUCCESS) {
    goto Failed;
  }
  Status = gBS->SetTimer (CompletionEvent, TimerPeriodic, 10000000);
  if (Status != EFI_SUCCESS) {
    gBS->CloseEvent (CompletionEvent);
    goto Failed;
  }
  Print (L"mvo.display-input.complete modes=2 keys=8\n");
  Stage = "completion-wait";
  for (;;) {
    Status = gBS->WaitForEvent (1, &CompletionEvent, &EventIndex);
    if (Status != EFI_SUCCESS || EventIndex != 0) {
      if (Status == EFI_SUCCESS) {
        Status = EFI_COMPROMISED_DATA;
      }
      gBS->CloseEvent (CompletionEvent);
      goto Failed;
    }
  }

Failed:
  Print (L"\nmvo.display-input.failure stage=%a status=%r\n", Stage, Status);
  return Status;
}
