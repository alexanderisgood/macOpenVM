// SPDX-License-Identifier: Apache-2.0
// Exact bounded positive enrollment helpers from the original trust-chain probe.
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
  Print (L"mvo.image-verification.update variable=%s status=%r\n", Name, Status);
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

