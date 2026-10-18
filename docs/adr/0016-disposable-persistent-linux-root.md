# ADR 16: qualify a persistent Linux root before guided installation

Status: accepted for a disposable offline integration fixture. Guided GUI and EFI
installation remain separate product acceptance requirements.

The matching 55 kernel/initramfs has booted into its early RAM shell. The exact
signed package set has been applied in temporary memory. Neither observation
proves a system installed on disk, init/service configuration or clean filesystem
shutdown. The cached initramfs's `root=` branch switches directly to the installed
root and bypasses the diskless service and console setup.

Use a new 8 GiB disposable VM disk with GPT, a 256 MiB FAT32 EFI system partition
and an ext4 root. This exercises the intended partition layout while allowing
direct-kernel boot to isolate installed-root acceptance from bootloader work.
Whole-device ext4 would be simpler, but would leave the installer layout untested.
An ESP's existence does not establish an installed EFI bootloader.

Before the first write, bind the fresh VM identity, configuration, exact disk
inode and retained live process owner. Require the expected capacity, one writable
target, no existing mounts/swaps/partitions and fresh blank-file evidence. Persist
the attempted/dirty observation before submitting any partition command. Preserve
failed attempts without resetting or reusing their disks.

Probe the actual filesystem tools before use. Apply the exact verified local
package set offline with scripts/hooks disabled. Explicitly stage the required
device essentials, init, serial console, hostname, UUID fstab and OpenRC service
links from the installed package contents. Validate those files and package/module
identities; inventory alone is insufficient. Avoid inheriting diskless modloop or
live-world settings.

Require successful unmount, no remaining target mounts, sync and offline filesystem
checks. Only after actual process exit, complete stream closure, stopped history
and available writer ownership may stopped metadata be changed. Both the OS disc
and support disc must be removable through the same protected product metadata
path, with exact original backups; avoid unguarded lab configuration rewrites.

Cold boot the same target with the qualified 55 pair, UUID root arguments and no
ISO images. Verify the actual ext4 root/UUID, persistent marker, kernel/modules,
offline networking and ordinary init/service shutdown. Keep install, cold boot,
filesystem checks and shutdown as separately observed outcomes. A later failure
must not erase earlier evidence or establish completion.

Acceptance: owned-target mutation, exact signed offline package application,
explicit persistent init/services, clean unmount/filesystem checks, unchanged VM
identity and protected inputs, disc-detached disk-root boot and ordinary shutdown.
GUI guidance, EFI bootloader, other distributions, Windows and power-loss recovery
still require their own evidence.
