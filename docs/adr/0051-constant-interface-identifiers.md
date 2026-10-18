# Compute literal renderer interface identifiers during compilation

Status: experimental in App68. Exact-header, native build/ABI and actual Windows
rendering checks pass. Overall FPS improvement remains unproven.

The App66 CS2 renderer profile contains repeated calls to
`dxmt::guid::make_guid_helper` and `parse_hex_digit` beneath shader binding and
QueryInterface. The native compiler recipe already uses O3. The public DXMT
header marks its helper constexpr, which permits compile-time evaluation without
requiring it at every runtime call site.

Give the existing literal GUID initialization a local constexpr value inside
`DXMT_DECLARE_UUIDOF_HELPER`. Return that value through the existing function;
pointer/reference forwarding, calling convention, interface IDs and object
lifetime remain unchanged. Preserve the header's original copyright and
MIT/zlib-derived notices within the LGPL DXMT source arrangement. This is an
independent modification of the legitimately obtained open-source header.

An actual-header probe compiled with matching C++20/O3/native definitions checks
known mixed-case GUID bits and a const-pointer variant for both versions. Both
executables exit0 and their actual parents are reaped. Generated original code
branches to the string parser; the candidate returns the same two literal words.
Parser-name references in the probe assembly fall from46 to0. This establishes
eliminated parsing in that generated function, not a measured game FPS increase.

Keep the currently admitted library unchanged until a separate native build is
signed and pinned. Preserve its prior bytes, complete source inventory, patch,
build recipe and actual child exits. Check exported ABI and then update the exact
library catalog/dependency inventory while the test VM is settled. Acceptance
requires actual Windows CS2 rendering at the same native viewport with matching
measurement scope and no new device loss. A result near the existing60Hz guest
mode must not be advertised as120FPS support. This is not a demonstrated fix for
the renderer's large memory footprint or the remaining gameplay hitch.

The native rebuild finishes with actual exit0; signing and strict verification
pass. All16 exported names and Mach-O imports match the previous library. A
complete modified-source inventory and prior immutable library are retained.
App68's opt-in native graphics-catalog check passes against the actual replacement,
followed by release/signing/provenance checks. The VM and actual App67 parent were
settled before installation; catalog, dependency inventory and SPDX reflect the
new bytes. QEMU34, reviewed signed guest driver and timing-disabled configuration
remain unchanged. The existing zstd archive emits a newer-macOS link warning;
this macOS27 GPU trial does not qualify macOS14 distribution.

Actual App68 Windows startup/sign-in and native3456×2168 CS2 work without manual
reconnect. Over20 seconds, its menu reports55.5 received/drawn frames/s versus
the preceding App67's60.4, with gaps17.89ms median/24.42ms p95/78.07ms worst.
Local DustII with bots reports58.4/s versus56.7, gaps15.80/30.35/149.22ms. Thus
results are mixed, including a slower menu and a longer worst gameplay gap. There
is no controlled or overall FPS-gain claim. Measurements identify Metal GPU
completion, not internal game FPS or physical scanout. The experimental build is
retained for eliminating demonstrated parser work, with prior bytes and rollback
recipe preserved. Long-term stability and a controlled performance comparison
remain open. Normal guest settlement and actual app-parent reap both exit0.
