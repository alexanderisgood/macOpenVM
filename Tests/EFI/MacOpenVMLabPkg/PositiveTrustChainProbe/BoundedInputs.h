// SPDX-License-Identifier: Apache-2.0
// Original bounded helpers retained from the settled positive PK probe.
#ifndef MVO_POSITIVE_TRUST_BOUNDED_INPUTS_H
#define MVO_POSITIVE_TRUST_BOUNDED_INPUTS_H

STATIC UINT16
ReadLe16 (CONST UINT8 *Bytes)
{
  return (UINT16)(Bytes[0] | ((UINT16)Bytes[1] << 8));
}

STATIC UINT32
ReadLe32 (CONST UINT8 *Bytes)
{
  return (UINT32)Bytes[0] | ((UINT32)Bytes[1] << 8) |
         ((UINT32)Bytes[2] << 16) | ((UINT32)Bytes[3] << 24);
}

STATIC EFI_STATUS
RequireMode (UINT8 ExpectedSetup, UINT8 ExpectedSecure)
{
  UINT8 Setup = 0xFF;
  UINT8 Secure = 0xFF;
  UINTN Size = sizeof (Setup);
  EFI_STATUS Status;

  Status = gRT->GetVariable (L"SetupMode", &gEfiGlobalVariableGuid, NULL, &Size, &Setup);
  if (Status != EFI_SUCCESS || Size != sizeof (Setup) || Setup != ExpectedSetup) {
    return EFI_ACCESS_DENIED;
  }
  Size = sizeof (Secure);
  Status = gRT->GetVariable (L"SecureBoot", &gEfiGlobalVariableGuid, NULL, &Size, &Secure);
  if (Status != EFI_SUCCESS || Size != sizeof (Secure) || Secure != ExpectedSecure) {
    return EFI_ACCESS_DENIED;
  }
  return EFI_SUCCESS;
}

STATIC EFI_STATUS
RequireMissingPk (VOID)
{
  UINTN Size = 0;
  EFI_STATUS Status;

  Status = gRT->GetVariable (L"PK", &gEfiGlobalVariableGuid, NULL, &Size, NULL);
  return Status == EFI_NOT_FOUND ? EFI_SUCCESS : EFI_ACCESS_DENIED;
}

STATIC EFI_STATUS
ReadBoundedFile (EFI_FILE_PROTOCOL *Root, CHAR16 *Name, UINT8 *Buffer,
                 UINTN Capacity, UINTN *Length)
{
  EFI_FILE_PROTOCOL *File = NULL;
  UINT8 Extra = 0;
  UINTN ExtraSize = sizeof (Extra);
  UINTN Size = Capacity;
  EFI_STATUS Status;
  EFI_STATUS CloseStatus;

  *Length = 0;
  ZeroMem (Buffer, Capacity);
  Status = Root->Open (Root, &File, Name, EFI_FILE_MODE_READ, 0);
  if (EFI_ERROR (Status)) {
    return Status;
  }
  if (File == NULL) {
    return EFI_COMPROMISED_DATA;
  }
  Status = File->Read (File, &Size, Buffer);
  if (!EFI_ERROR (Status)) {
    if (Size > Capacity) {
      Status = EFI_COMPROMISED_DATA;
    } else {
      Status = File->Read (File, &ExtraSize, &Extra);
      if (!EFI_ERROR (Status) && ExtraSize != 0) {
        Status = EFI_COMPROMISED_DATA;
      }
    }
  }
  CloseStatus = File->Close (File);
  if (!EFI_ERROR (Status) && EFI_ERROR (CloseStatus)) {
    Status = CloseStatus;
  }
  if (!EFI_ERROR (Status)) {
    *Length = Size;
  }
  return Status;
}

STATIC BOOLEAN
ValidTimestamp (CONST UINT8 *Time)
{
  STATIC CONST UINT8 MonthDays[12] = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
  UINT16 Year = ReadLe16 (Time);
  UINT8 Month = Time[2];
  UINT8 MaximumDay;

  if (Year < 1900 || Year > 9999 || Month < 1 || Month > 12 ||
      Time[4] > 23 || Time[5] > 59 || Time[6] > 59 || Time[7] != 0 ||
      ReadLe32 (Time + 8) != 0 || ReadLe16 (Time + 12) != 0 ||
      Time[14] != 0 || Time[15] != 0) {
    return FALSE;
  }
  MaximumDay = MonthDays[Month - 1];
  if (Month == 2 && (Year % 4 == 0) && ((Year % 100 != 0) || (Year % 400 == 0))) {
    MaximumDay++;
  }
  return Time[3] >= 1 && Time[3] <= MaximumDay;
}

STATIC EFI_STATUS
ValidateInputs (CONST UINT8 *Auth, UINTN AuthSize, CONST UINT8 Esl[ESL_SIZE + 1])
{
  UINT32 CertificateLength;

  // A single X.509 ESL entry must contain exactly the already-published test
  // certificate. SignatureOwner is an identifier, not an authorization key.
  if (CompareMem (Esl, &gEfiCertX509Guid, sizeof (EFI_GUID)) != 0 ||
      ReadLe32 (Esl + 16) != ESL_SIZE || ReadLe32 (Esl + 20) != 0 ||
      ReadLe32 (Esl + 24) != sizeof (EFI_GUID) + sizeof (mFixtureCertificate) ||
      CompareMem (Esl + 44, mFixtureCertificate, sizeof (mFixtureCertificate)) != 0) {
    return EFI_COMPROMISED_DATA;
  }
  // AUTH2 consists of EFI_TIME(16), WIN_CERTIFICATE_UEFI_GUID(24), nonempty
  // supplied PKCS7 data, and the exact ESL. Firmware processes that descriptor;
  // this initial Setup Mode enrollment is not proof of signature enforcement.
  // The probe neither creates signatures nor changes authentication policy.
  if (AuthSize < 40 + 1 + ESL_SIZE || AuthSize > AUTH_CAPACITY) {
    return EFI_COMPROMISED_DATA;
  }
  CertificateLength = ReadLe32 (Auth + 16);
  if (CertificateLength < 25 || CertificateLength > AuthSize - 16 - ESL_SIZE ||
      AuthSize != 16 + (UINTN)CertificateLength + ESL_SIZE ||
      !ValidTimestamp (Auth) || ReadLe16 (Auth + 20) != 0x0200 ||
      ReadLe16 (Auth + 22) != WIN_CERT_TYPE_EFI_GUID ||
      CompareMem (Auth + 24, &gEfiCertPkcs7Guid, sizeof (EFI_GUID)) != 0 ||
      CompareMem (Auth + 16 + CertificateLength, Esl, ESL_SIZE) != 0) {
    return EFI_COMPROMISED_DATA;
  }
  return EFI_SUCCESS;
}

#endif
