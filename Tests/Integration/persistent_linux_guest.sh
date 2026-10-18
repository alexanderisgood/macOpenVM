#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Disposable lab only: called after host identity, lease, media and blank guards.
# Inputs: verified temporary tool root, work directory, nonce, root UUID.
set -eu
ram=$1 work=$2 nonce=$3 root_uuid=$4
export LC_ALL=C
target=/mnt/mvo-installed
fact() { printf '\n%s.install.%s=%s\n' "$nonce" "$1" "$2"; }
get_uuid() { blkid "$1" | sed -n 's/.* UUID="\([^"]*\)".*/\1/p'; }
phase=guard
finish_install() {
    s=$?
    if [ "$s" -ne 0 ]; then
        sync
        if grep -q " $target " /proc/mounts; then umount "$target"; fi
        if grep -q " $ram/dev " /proc/mounts; then umount "$ram/dev"; fi
        sync
    fi
    fact phase "$phase"
    fact exit "$s"
    exit "$s"
}
trap finish_install EXIT
t() { /bin/busybox chroot "$ram" /bin/busybox env -i PATH=/sbin:/usr/sbin:/usr/bin:/bin:/tmp/mvo-applets LC_ALL=C "$@"; }
[ "$(uname -m)" = aarch64 ]
[ "$(uname -r)" = 6.18.52-0-virt ]
[ "$(cat /sys/class/block/vda/size)" = 16777216 ]
[ "$(cat /sys/class/block/vda/ro)" = 0 ]
[ ! -e /sys/class/block/vda/vda1 ]
[ ! -e "$target" ]
if grep -q '^/dev/vda' /proc/mounts /proc/swaps; then exit 70; else [ "$?" = 1 ]; fi
for offset in 0 16777215; do
    [ "$(dd if=/dev/vda bs=512 skip="$offset" count=1 2>/dev/null | sha256sum | cut -d' ' -f1)" = 076a27c79e5ace2a3d47f9dd2e83e4ff6ea8872b3c2218f66c92b89b55f36560 ]
done
mount --bind /dev "$ram/dev"
phase=partition
printf 'label: gpt\nunit: sectors\n\nstart=2048,size=524288,type=U\nstart=526336,type=L\n' >"$work/layout"
t sfdisk /dev/vda <"$work/layout"
mdev -s
[ "$(cat /sys/class/block/vda/vda1/start)" = 2048 ]
[ "$(cat /sys/class/block/vda/vda1/size)" = 524288 ]
[ "$(cat /sys/class/block/vda/vda2/start)" = 526336 ]
fact partition 0
phase=format
t mkfs.fat -F 32 -n MVO_ESP /dev/vda1
fact fatFormatted 1
t mkfs.ext4 -q -U "$root_uuid" -L MVO_ROOT -E lazy_itable_init=0,lazy_journal_init=0 /dev/vda2
fact rootFormatted 1
[ "$(get_uuid /dev/vda2)" = "$root_uuid" ]
esp_uuid=$(get_uuid /dev/vda1)
fact espUUID "$esp_uuid"
fact format 0
mkdir -m 700 "$target"
mount -t ext4 /dev/vda2 "$target"
phase=packages
APK_CONFIG=/dev/null /sbin/apk --root "$target" --arch aarch64 --no-network --no-cache --no-logfile --no-progress --no-pretty-print --no-interactive --repositories-file "$work/sim.repositories" --keys-dir /media/mvo-support/keys add --initdb --no-scripts --no-commit-hooks alpine-base=3.24.2-r0 sfdisk=2.42.3-r1 e2fsprogs=1.47.4-r0 linux-virt=6.18.55-r0 mkinitfs=3.14.1-r0 dosfstools=4.2-r2
cmp "$ram/lib/apk/db/installed" "$target/lib/apk/db/installed"
cmp "$ram/etc/apk/world" "$target/etc/apk/world"
# Credential contents are compared locally, never emitted or changed.
cmp "$ram/etc/passwd" "$target/etc/passwd"
cmp "$ram/etc/shadow" "$target/etc/shadow"
fact packages 49
phase=configure
[ ! -e "$target/dev/null" ]
mknod -m 666 "$target/dev/null" c 1 3
# Alpine's authenticated BusyBox trigger installs the separate bbsuid applets
# first. Reproduce only that link setup; retain packaged modes and credentials.
chroot "$target" /bin/bbsuid --install
chroot "$target" /bin/busybox --install -s
phase=applets
chroot "$target" /bin/busybox env -i PATH=/sbin:/usr/sbin:/usr/bin:/bin /bin/sh -c '
set -eu
for name in init getty login mkdir cpio awk find sort install; do
    p=$(command -v "$name")
    case "$p" in /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*) test -x "$p";; *) exit 1;; esac
    printf "Installed applet %s: %s\n" "$name" "$p"
done'
phase=configure-services
for tool in depmod modprobe modinfo; do [ "$(readlink "$target/sbin/$tool")" = ../bin/kmod ]; done
chroot "$target" /sbin/depmod -a 6.18.55-0-virt
[ -s "$target/lib/modules/6.18.55-0-virt/modules.dep" ]
[ "$(ls "$target/lib/modules")" = 6.18.55-0-virt ]
mkdir -p "$target/boot/efi" "$target/etc/local.d" "$target/usr/local/sbin"
printf 'UUID=%s / ext4 defaults 0 1\nUUID=%s /boot/efi vfat defaults 0 2\ntmpfs /tmp tmpfs nosuid,nodev 0 0\n' "$root_uuid" "$esp_uuid" >"$target/etc/fstab"
printf 'macopenvm-lab\n' >"$target/etc/hostname"
printf 'virtio_blk\nvirtio_mmio\next4\nvfat\n' >"$target/etc/modules"
printf '\nhvc0::respawn:/sbin/getty -L 0 hvc0 vt100\n' >>"$target/etc/inittab"
[ "$(grep -c '^hvc0::respawn:' "$target/etc/inittab")" = 1 ]
grep -qx hvc0 "$target/etc/securetty"
printf '\ncritical_mounts="/boot/efi"\n' >>"$target/etc/conf.d/localmount"
for level in sysinit boot default shutdown; do
    mkdir -p "$target/etc/runlevels/$level"
    [ -z "$(ls -A "$target/etc/runlevels/$level")" ]
done
for svc in devfs sysfs dmesg mdev hwdrivers; do ln -s /etc/init.d/$svc "$target/etc/runlevels/sysinit/$svc"; done
for svc in modules fsck root localmount hostname sysctl bootmisc; do ln -s /etc/init.d/$svc "$target/etc/runlevels/boot/$svc"; done
for svc in killprocs mount-ro; do ln -s /etc/init.d/$svc "$target/etc/runlevels/shutdown/$svc"; done
ln -s /etc/init.d/local "$target/etc/runlevels/default/local"
printf '%s\n%s\n%s\n' "$nonce" "$root_uuid" "$esp_uuid" >"$target/etc/macopenvm-lab-identity"
cat >"$target/etc/local.d/macopenvm-witness.start" <<'START'
#!/bin/sh
/usr/local/sbin/macopenvm-witness </dev/null >/dev/hvc0 2>&1 &
exit 0
START
cat >"$target/usr/local/sbin/macopenvm-witness" <<'WITNESS'
#!/bin/sh
set -eu
export PATH=/sbin:/usr/sbin:/usr/bin:/bin LC_ALL=C
nonce=$(sed -n 1p /etc/macopenvm-lab-identity)
root_uuid=$(sed -n 2p /etc/macopenvm-lab-identity)
esp_uuid=$(sed -n 3p /etc/macopenvm-lab-identity)
fact() { printf '\n%s.cold.%s=%s\n' "$nonce" "$1" "$2"; }
get_uuid() { blkid "$1" | sed -n 's/.* UUID="\([^"]*\)".*/\1/p'; }
finish() { s=$?; fact exit "$s"; sync; /sbin/poweroff; }
trap finish EXIT
i=0
until [ -e /run/openrc/started/local ]; do i=$((i+1)); [ "$i" -lt 30 ]; sleep 1; done
for svc in devfs sysfs mdev hwdrivers modules fsck root localmount hostname sysctl bootmisc local; do
    rc-service "$svc" status >/dev/null
done
fact services 0
[ "$(uname -r)" = 6.18.55-0-virt ]
fact kernel "$(uname -r)"
[ "$(ls /lib/modules)" = 6.18.55-0-virt ]
fact modules "$(ls /lib/modules)"
[ "$(ls /sys/class/net)" = lo ]
fact network lo
[ "$(get_uuid /dev/vda2)" = "$root_uuid" ]
awk '$1=="/dev/vda2" && $2=="/" && $3=="ext4" && $4 ~ /(^|,)rw(,|$)/ {ok=1} END{exit !ok}' /proc/mounts
fact rootUUID "$root_uuid"
fact rootRW 1
[ "$(get_uuid /dev/vda1)" = "$esp_uuid" ]
awk '$1=="/dev/vda1" && $2=="/boot/efi" && $3=="vfat" {ok=1} END{exit !ok}' /proc/mounts
fact espUUID "$esp_uuid"
[ ! -e /dev/sda ] && [ ! -e /dev/sdb ]
fact discsAbsent 1
prior=0
if [ -e /var/lib/macopenvm-cold-boot ]; then
    [ "$(cat /var/lib/macopenvm-cold-boot)" = "$nonce" ]
    prior=1
fi
fact priorWrite "$prior"
printf '%s\n' "$nonce" >/var/lib/macopenvm-cold-boot
sync
[ "$(cat /var/lib/macopenvm-cold-boot)" = "$nonce" ]
fact persistentWrite 1
fact complete 1
WITNESS
chmod 755 "$target/etc/local.d/macopenvm-witness.start" "$target/usr/local/sbin/macopenvm-witness"
chroot "$target" /bin/sh -n /usr/local/sbin/macopenvm-witness
cmp "$ram/etc/passwd" "$target/etc/passwd"
cmp "$ram/etc/shadow" "$target/etc/shadow"
fact configured 0
phase=filesystem-check
sync
umount "$target"
if grep -q '^/dev/vda' /proc/mounts /proc/swaps; then exit 71; else [ "$?" = 1 ]; fi
t e2fsck -fn /dev/vda2
t fsck.fat -n /dev/vda1
fact filesystemCheck 0
umount "$ram/dev"
sync
fact rootUUID "$root_uuid"
phase=complete
