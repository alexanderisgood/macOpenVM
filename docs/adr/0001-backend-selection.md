# ADR 1: select backends by verified guest requirements

Status: accepted for the Linux feasibility slice; Windows selection provisional.

The first actual Windows11 ARM64 installer boot (private development record omitted)
now reached the English setup screen through QEMU/HVF on the audited host. This
supports continuing that backend evaluation; it does not establish installation,
protected-platform compliance, drivers or native application presentation.

Use BackendAPI plain values and an explicit lifecycle contract. Linux uses public
AppleVz on ARM64. Windows evaluates QEMU/HVF with a pinned versioned ARM machine,
explicit accelerated CPU, persistent EFI/TPM identity and native signed drivers.
Reject assuming Linux/EFI/config validation proves Windows, automatic emulation
fallback, a commercial application dependency, and direct VZ types in VM config.

Acceptance: actual Linux boot/display/input; actual compliant Windows install and
device health before support; backend selection records evidence and limitations.

## Host floor and interrupt backend audit — 2026-10-07

The settled host-floor evidence (private development record omitted)
separates the macOS 14 product requirement from the current private evaluation
runtime. Its executable declares minimum 27 / SDK 27, its 13 mandatory non-system
dylibs declare minimum 26, and later Hypervisor GIC/SME/EL2 imports are strong.
Retained build flags contain no explicit deployment target; inherited host/CLT
defaults are an inference because the complete historical environment was not
recorded. These binary floors do not establish intrinsic source-version floors.

A separate build targeting 14.0 and compatible dependency chain may investigate the
source-supported public `hvf,kernel-irqchip=off`/`gic-version=2` route. CPU execution
remains hardware accelerated; the interrupt device is emulated and limited to
eight CPUs. The explicit override is required for pinned `virt-11.1`. Base ARM
HVF APIs are available from 11 and VM configuration/IPA APIs from 13; native GIC and
EL2 require 15, and SME requires 15.2. TPM2/PPI, read-only firmware and authenticated
variable/TPM persistence requirements remain intact. No private API, verification
skip, weak entropy or TCG fallback follows from this backend choice.

Acceptance requires an actual macOS 14 loader/API test with the full dependency chain,
older-CPU strong-entropy verification, then the owned EFI/TPM/persistence/display
contracts on the separately identified interrupt backend. Actual Windows
installation, ACPI/GIC/device health and applicable VBS requirements remain
independent gates. Source support, SDK declarations and macOS 27 results do not
establish older-host support. The product minimum and current Linux/Windows
support status are unchanged.

## Native Windows installer display checkpoint

Actual native-window evidence (private development record omitted) now covers the approved offline installer, Liquid Glass presentation, synthesized Tab/Shift–Tab, display reconnect and app-quit survival under the retained Swift worker. All runtime children settled; media and blank disk preserved. This remains experimental. Next: pointer routing using the same rendered-viewport transform, followed by native geometry/fullscreen verification and the guided installation workflow. No installation, Retina, physical keyboard or full compatibility claim.
