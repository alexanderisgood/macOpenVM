# SPDX-License-Identifier: Apache-2.0
[Defines]
  PLATFORM_NAME = MacOpenVMFirmwareLab
  PLATFORM_GUID = 48336928-cfd5-486e-8a38-9735a3bb7d44
  PLATFORM_VERSION = 0.1
  DSC_SPECIFICATION = 0x0001001C
  OUTPUT_DIRECTORY = Build/MacOpenVMFirmwareLab
  SUPPORTED_ARCHITECTURES = AARCH64
  BUILD_TARGETS = NOOPT
  SKUID_IDENTIFIER = DEFAULT

[LibraryClasses]
  UefiApplicationEntryPoint|MdePkg/Library/UefiApplicationEntryPoint/UefiApplicationEntryPoint.inf
  UefiLib|MdePkg/Library/UefiLib/UefiLib.inf
  UefiBootServicesTableLib|MdePkg/Library/UefiBootServicesTableLib/UefiBootServicesTableLib.inf
  UefiRuntimeServicesTableLib|MdePkg/Library/UefiRuntimeServicesTableLib/UefiRuntimeServicesTableLib.inf
  BaseMemoryLib|MdePkg/Library/BaseMemoryLib/BaseMemoryLib.inf
  BaseLib|MdePkg/Library/BaseLib/BaseLib.inf
  MemoryAllocationLib|MdePkg/Library/UefiMemoryAllocationLib/UefiMemoryAllocationLib.inf
  DebugLib|MdePkg/Library/BaseDebugLibNull/BaseDebugLibNull.inf
  PrintLib|MdePkg/Library/BasePrintLib/BasePrintLib.inf
  PcdLib|MdePkg/Library/BasePcdLibNull/BasePcdLibNull.inf
  DevicePathLib|MdePkg/Library/UefiDevicePathLib/UefiDevicePathLib.inf
  RegisterFilterLib|MdePkg/Library/RegisterFilterLibNull/RegisterFilterLibNull.inf
  CpuLib|MdePkg/Library/BaseCpuLib/BaseCpuLib.inf
  StackCheckLib|MdePkg/Library/StackCheckLib/StackCheckLib.inf
  # The optional hook is empty; the real cookie check and failure interrupt remain.
  StackCheckFailureHookLib|MdePkg/Library/StackCheckFailureHookLibNull/StackCheckFailureHookLibNull.inf

[Components]
  MacOpenVMLabPkg/PlatformProbe/PlatformProbe.inf
  MacOpenVMLabPkg/TpmNvProbe/TpmNvPrepare.inf
  MacOpenVMLabPkg/TpmNvProbe/TpmNvVerify.inf
  MacOpenVMLabPkg/PkEnrollmentProbe/PkEnrollmentProbe.inf
  MacOpenVMLabPkg/PositiveTrustChainProbe/PositiveTrustChainProbe.inf
  MacOpenVMLabPkg/AuthenticatedVariableProbe/AuthenticatedVariableProbe.inf
  MacOpenVMLabPkg/DisplayInputProbe/DisplayInputProbe.inf
  MacOpenVMLabPkg/MeasurementConsistencyProbe/MeasurementConsistencyProbe.inf
  MacOpenVMLabPkg/NvmeProbe/NvmePrepare.inf
  MacOpenVMLabPkg/NvmeProbe/NvmeVerify.inf
  MacOpenVMLabPkg/ImageVerificationProbe/ImageVerificationProbe.inf
