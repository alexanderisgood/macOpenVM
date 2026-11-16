# 68. Space-efficient Windows setup without steady-state compression

Status: implemented; broader device and clean-machine release qualification remains open.

New Windows VMs use a 128 GiB sparse capacity limit, shared by the app and CLI.
The limit is not preallocation. Keep the existing host-sized CPU/RAM defaults,
host reserves, writeback cache with guest flushes, and discard. Show recommended
hardware first, with explicit customization available. Existing VMs are unchanged.

Guest Tools offers a checked, clearly described storage option alongside its
matching-driver install. It runs the Windows system `powercfg /hibernate off`
command, checks that the hibernation file is absent, then runs `defrag /L` on
the actual Windows volume. This disables guest hibernation and Fast Startup;
the UI explains that tradeoff and users can opt out. Preserve the choice across
UAC, report hibernation and reclaim outcomes separately, and never equate a
successful retrim request with measured host space savings. Launch only absolute
System32 executables with fixed arguments, no shell or downloaded optimizer.

Leave paging, recovery, security, updates, user files and compression settings
unchanged. No WinSxS deletion, reset-base, automatic Downloads/Recycle Bin cleanup,
partition relocation or zero-filling. Compression has workload-dependent CPU
costs and is not the performance default. Storage settings remain available for
users to inspect Windows' own usage categories.

Acceptance: sparse default parity and manual override; opted-out storage causes
no commands; payload validation fails before any change; command and verification
failures cannot report success; reclaim still has its own outcome; UAC preserves
selection; repeat runs are safe; UI remains responsive and never auto-restarts;
taskbar-aware placement, scrolling and keyboard access on short displays;
reproducible ARM64 tools build and ISO readback; native Windows hibernation-file,
free-space and recovery checks. This is a setup improvement, not a native-speed
claim or a completed unattended Windows installer.

Verification: the C orchestration fixture covers opt-out, invalid volume, repeat
runs, command failure, verification failure and independent reclaim results.
The eight Guest Tools tests pass, and repeated ARM64 builds produce identical
media and installer hashes for all three profiles. Existing Windows creation
tests cover the shared default and explicit overrides. Private guest artifacts
are excluded from the source distribution.

References: Microsoft [powercfg](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options),
[defrag](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/defrag),
and [Compact OS](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/compact-os).
