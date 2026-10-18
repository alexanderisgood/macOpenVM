#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Fixed LAB-only orchestration on a freshly copied private root. Never a product autorun.
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
umask 077
mode=$1
state=/var/lib/macopenvm-agent-lab
log=/run/macopenvm-agent.log
program=/usr/local/libexec/macopenvm-agent/macopenvm-agent
phase=guard
target=
fact() { printf '\n%s.%s=%s\n' "$marker" "$1" "$2"; }
finish() {
    code=$?
    trap - EXIT
    if [ -n "$target" ] && grep -q " $target " /proc/mounts; then sync; umount "$target" || true; fi
    fact phase "$phase"
    fact exit "$code"
    sync
    /sbin/poweroff
    exit "$code"
}
uuid_ok() { printf '%s\n' "$1" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; }
get_uuid() { blkid "$1" | sed -n 's/.* UUID="\([^"]*\)".*/\1/p'; }
plain() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u "$1")" = 0 ]; }
carrier_file() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %h "$1")" = 1 ] || return 1
    [ "$(stat -c %s "$1")" -gt 0 ] && [ "$(stat -c %s "$1")" -le "$2" ] || return 1
}
owned_log() {
    [ -f "$log" ] && [ ! -L "$log" ] && [ "$(stat -c %h "$log")" = 1 ]
    [ "$(stat -c %u "$log")" = "$(id -u macopenvm-agent)" ]
    [ "$(stat -c %a "$log")" = 600 ]
    plain "$log.owner"
    [ "$(stat -c %h "$log.owner")" = 1 ] && [ "$(stat -c %a "$log.owner")" = 600 ]
    [ "$(cat "$log.owner")" = "macopenvm-agent-log-v1:$(stat -c '%d:%i' "$log")" ]
    [ "$(stat -c %s "$log")" -le 65536 ]
}
bounded_wait() {
    elapsed=$(cut -d. -f1 /proc/uptime)
    [ "$elapsed" -lt "$deadline" ]
}
support_facts() {
    observation=$1
    case "$observation" in initial|ready|timeout) ;; *) return 1;; esac
    fact "support.$observation.uptime" "$(cut -d. -f1 /proc/uptime)"
    if [ -e /sys/class/block/sda ]; then fact "support.$observation.sysSda" 1;
    else fact "support.$observation.sysSda" 0; fi
    if [ -b /dev/sda ]; then fact "support.$observation.devSda" 1;
    else fact "support.$observation.devSda" 0; fi
    if [ -r /sys/class/block/sda/ro ]; then
        readonly=$(cat /sys/class/block/sda/ro)
        case "$readonly" in 0|1) fact "support.$observation.ro" "$readonly";; *) return 1;; esac
    else fact "support.$observation.ro" absent; fi
    usb_count=0
    for node in /sys/bus/usb/devices/*; do
        # Count device entries, including root hubs, without reading any identifier.
        if [ -e "$node/idVendor" ]; then usb_count=$((usb_count+1)); fi
    done
    storage_count=0
    for node in /sys/bus/usb/drivers/usb-storage/*:*; do
        if [ -e "$node" ]; then storage_count=$((storage_count+1)); fi
    done
    fact "support.$observation.usbDeviceCount" "$usb_count"
    fact "support.$observation.storageBindingCount" "$storage_count"
}
account_hash() { grep -v '^macopenvm-agent:' "$1" | sha256sum | cut -d' ' -f1; }
accounts_preserved() {
    for file in passwd shadow group gshadow; do
        if [ "$(cat "$state/before/$file.present")" = 1 ]; then
            plain "/etc/$file"
            [ "$(account_hash "/etc/$file")" = "$(cat "$state/before/$file.hash")" ]
            [ "$(stat -c '%a:%u:%g' "/etc/$file")" = "$(cat "$state/before/$file.mode")" ]
        else [ ! -e "/etc/$file" ] && [ ! -L "/etc/$file" ]; fi
    done
    [ "$(cat /etc/macopenvm-agent-unrelated-sentinel)" = "$(sed -n 1p "$state/config")" ]
    grep -q '^nobody:' /etc/passwd
}
enrollment_facts() {
    for file in cert.pem key.pem ca.pem vm-id; do
        path=/etc/macopenvm-agent/$file
        [ -f "$path" ] && [ ! -L "$path" ] && [ "$(stat -c %h "$path")" = 1 ]
        printf '%s %s %s\n' "$file" "$(sha256sum "$path" | cut -d' ' -f1)" "$(stat -c '%a:%u:%g' "$path")"
    done
}
enrollment_preserved() {
    # Private comparison only: never emit credential fingerprints into transcripts.
    [ "$(enrollment_facts)" = "$(cat "$state/enrollment-before")" ]
}
reservation_state() {
    expected_status=$1
    case "$expected_status" in installed|removed) ;; *) return 1;; esac
    reservation=/var/lib/macopenvm-agent-account
    [ -d "$reservation" ] && [ ! -L "$reservation" ]
    [ "$(stat -c '%a:%u:%g' "$reservation")" = 700:0:0 ]
    [ "$(ls -A "$reservation")" = record ]
    plain "$reservation/record"
    [ "$(stat -c '%a:%u:%g:%h' "$reservation/record")" = 600:0:0:1 ]
    [ "$(stat -c %s "$reservation/record")" -le 1024 ]
    [ "$(awk 'END {print NR}' "$reservation/record")" = 12 ]
    [ "$(sed -n 1p "$reservation/record")" = macopenvm-agent-account-v1 ]
    [ "$(sed -n 2p "$reservation/record")" = "vm-id=$(printf '%s' "$vm_id" | tr 'A-F' 'a-f')" ]
    [ "$(sed -n 3p "$reservation/record")" = "service-uid=$(id -u macopenvm-agent)" ]
    [ "$(sed -n 4p "$reservation/record")" = "service-gid=$(id -g macopenvm-agent)" ]
    [ "$(sed -n 8p "$reservation/record")" = "credentials=$expected_status" ]
    # Keep account-row hashes private. The signed installer validates their exact contract.
    if [ -f "$state/reservation-account-before" ]; then
        plain "$state/reservation-account-before"
        [ "$(stat -c '%a:%h' "$state/reservation-account-before")" = 600:1 ]
        [ "$(stat -c %s "$state/reservation-account-before")" -le 1024 ]
        [ "$(sed -n '1,7p' "$reservation/record")" = "$(cat "$state/reservation-account-before")" ]
    else
        [ "$boot" = 1 ] && [ "$expected_status" = installed ]
        sed -n '1,7p' "$reservation/record" >"$state/reservation-account-before"
    fi
    if [ "$expected_status" = removed ]; then
        [ "$(sed -n '9,12p' "$reservation/record")" = "$(printf 'cert-sha256=-\nkey-sha256=-\nca-sha256=-\nvm-id-sha256=-')" ]
    fi
}
removed_installation() {
    ! pidof macopenvm-agent >/dev/null 2>&1
    for owned in /usr/local/libexec/macopenvm-agent /etc/macopenvm-agent /etc/init.d/macopenvm-agent /var/lib/macopenvm-agent /etc/runlevels/default/macopenvm-agent; do
        [ ! -e "$owned" ] && [ ! -L "$owned" ]
    done
    accounts_preserved
    [ "$(id -u macopenvm-agent):$(id -g macopenvm-agent)" = "$(cat "$state/service-identity")" ]
    grep -q '^macopenvm-agent:!:' /etc/shadow
    grep -q '^macopenvm-agent:[^:]*:[0-9]*:[0-9]*:[^:]*:/nonexistent:/sbin/nologin$' /etc/passwd
    reservation_state removed
}
run_setup() {
    setup_label=$1
    shift
    case "$setup_label" in install|keepUninstall|reinstall|removeUninstall|reenroll|reenrollRemoveUninstall) ;; *) return 1;; esac
    diagnostic=/run/macopenvm-agent-install.stderr
    [ ! -e "$diagnostic" ] && [ ! -L "$diagnostic" ]
    (set -C; : >"$diagnostic")
    chmod 600 "$diagnostic"
    fact "$setup_label.started" 1
    if /bin/sh "$@" >/dev/null 2>"$diagnostic"; then setup_status=0; else setup_status=$?; fi
    fact "$setup_label.exit" "$setup_status"
    fact "$setup_label.finished" 1
    if [ "$setup_status" -ne 0 ]; then
        # The setup program's exec3 admits only its static die/trap diagnostics.
        # Never forward native utility output, paths, controls, or oversized lines.
        if plain "$diagnostic" && [ "$(stat -c %h "$diagnostic")" = 1 ] && [ "$(stat -c %s "$diagnostic")" -le 4096 ]; then
            awk 'index($0,"Experimental agent setup: ")==1 && length($0)<=128 && $0 ~ /^[ -~]+$/ && shown<2 {
              message=substr($0,length("Experimental agent setup: ")+1)
              if(length("mvo.setup-error ")+length(message)<=128) {printf "mvo.setup-error %s\n",message; shown++}
            }' "$diagnostic" || true
        fi
        exit "$setup_status"
    fi
    plain "$diagnostic"
    [ "$(stat -c %h "$diagnostic")" = 1 ] && [ "$(stat -c %s "$diagnostic")" -le 4096 ]
    rm "$diagnostic"
}
process_facts() {
    label=$1
    pid=$(pidof macopenvm-agent)
    case "$pid" in ''|*[!0-9]*) return 1;; esac
    [ "$(readlink "/proc/$pid/exe")" = "$program" ]
    uid=$(id -u macopenvm-agent); gid=$(id -g macopenvm-agent)
    fact "$label.inspectedUid" "$(awk '/^Uid:/{print $2":"$3":"$4":"$5}' "/proc/$pid/status")"
    fact "$label.inspectedGid" "$(awk '/^Gid:/{print $2":"$3":"$4":"$5}' "/proc/$pid/status")"
    fact "$label.inspectedCapEff" "$(awk '/^CapEff:/{print $2}' "/proc/$pid/status")"
    fact "$label.inspectedNoNewPrivs" "$(awk '/^NoNewPrivs:/{print $2}' "/proc/$pid/status")"
    [ "$uid" -gt 0 ] && [ "$gid" -gt 0 ]
    [ "$(awk '/^Uid:/{print $2":"$3":"$4":"$5}' "/proc/$pid/status")" = "$uid:$uid:$uid:$uid" ]
    [ "$(awk '/^Gid:/{print $2":"$3":"$4":"$5}' "/proc/$pid/status")" = "$gid:$gid:$gid:$gid" ]
    [ "$(awk '/^CapEff:/{print $2}' "/proc/$pid/status")" = 0000000000000000 ]
    [ "$(awk '/^NoNewPrivs:/{print $2}' "/proc/$pid/status")" = 1 ]
    grep -q '/lib/libssl.so.3' "/proc/$pid/maps"
    grep -q '/lib/libcrypto.so.3' "/proc/$pid/maps"
    [ "$(ls /sys/class/net)" = lo ]
    awk '/^mvo.agent-tls.runtime openssl=OpenSSL 3\.5\.9 / {n++} END {exit n!=1}' "$log"
    if [ -f "$state/service-identity" ]; then
        [ "$(cat "$state/service-identity")" = "$uid:$gid" ]
    else printf '%s\n' "$uid:$gid" >"$state/service-identity"; fi
    fact "$label.pid" "$pid"; fact "$label.uid" "$uid"; fact "$label.gid" "$gid"
    fact "$label.capEff" 0000000000000000
    fact "$label.noNewPrivs" 1; fact "$label.openssl" 3.5.9; fact "$label.nic" lo
}
wait_ready() {
    while ! grep -qx 'mvo.agent-tls.ready port=4050 version=1' "$log" 2>/dev/null; do
        bounded_wait; sleep 1
    done
    owned_log
    rc-service macopenvm-agent status >/dev/null 2>&1
}
wait_health() {
    expected=$1
    while [ "$(grep -c '^mvo.agent-tls.health-complete version=0.1.0 architecture=arm64$' "$log" || true)" -lt "$expected" ]; do
        bounded_wait; sleep 1
    done
    [ "$(stat -c %s "$log")" -le 65536 ]
}

if [ "$mode" = prepare ]; then
    [ "$#" = 6 ]
    marker=$2 vm_id=$3 pin=$4 root_uuid=$5 esp_uuid=$6
    printf '%s\n' "$marker" | grep -Eq '^mvo-agent-install-[0-9a-f]{32}$'
    uuid_ok "$vm_id"; uuid_ok "$root_uuid"
    printf '%s\n' "$pin" | grep -Eq '^[0-9a-f]{64}$'
    printf '%s\n' "$esp_uuid" | grep -Eq '^[0-9A-F]{4}-[0-9A-F]{4}$'
    trap finish EXIT
    [ "$(uname -m)" = aarch64 ] && [ "$(uname -r)" = 6.18.52-0-virt ]
    [ "$(ls /sys/class/net)" = lo ]
    [ "$(cat /sys/class/block/vda/size)" = 16777216 ]
    [ "$(cat /sys/class/block/vda/vda2/start)" = 526336 ]
    [ "$(get_uuid /dev/vda2)" = "$root_uuid" ]
    [ "$(get_uuid /dev/vda1)" = "$esp_uuid" ]
    if grep -q '^/dev/vda' /proc/mounts /proc/swaps; then exit 70; else [ "$?" = 1 ]; fi
    target=/mnt/macopenvm-agent-copy
    [ ! -e "$target" ] && [ ! -L "$target" ]
    mkdir -m 700 "$target"
    mount -t ext4 /dev/vda2 "$target"
    phase=disable-owned-witness
    hook=$target/etc/local.d/macopenvm-witness.start
    backup=$hook.disabled-${marker#mvo-agent-install-}
    plain "$hook"
    [ "$(stat -c %s "$hook")" = 80 ] && [ "$(stat -c %a "$hook")" = 755 ]
    [ "$(sha256sum "$hook" | cut -d' ' -f1)" = 1e24d9f0e41d1e2ee4ee0d982be1f79d1df9a2e1af127af1d9943f9653b2a6f9 ]
    [ ! -e "$backup" ] && [ ! -L "$backup" ]
    [ "$(sed -n 2p "$target/etc/macopenvm-lab-identity")" = "$root_uuid" ]
    [ "$(sed -n 3p "$target/etc/macopenvm-lab-identity")" = "$esp_uuid" ]
    mv "$hook" "$backup"
    [ "$(stat -c %a "$backup")" = 755 ]
    [ "$(sha256sum "$backup" | cut -d' ' -f1)" = 1e24d9f0e41d1e2ee4ee0d982be1f79d1df9a2e1af127af1d9943f9653b2a6f9 ]
    [ ! -e "$hook" ]
    phase=stage-fixed-lab-hook
    [ ! -e "$target$state" ] && [ ! -L "$target$state" ]
    [ ! -e "$target/etc/macopenvm-agent-unrelated-sentinel" ]
    mkdir -m 700 "$target$state" "$target$state/before"
    printf '%s\n%s\n%s\n%s\n%s\n' "$marker" "$vm_id" "$pin" "$root_uuid" "$esp_uuid" >"$target$state/config"
    for file in passwd shadow group gshadow; do
        if [ -e "$target/etc/$file" ]; then
            plain "$target/etc/$file"
            ! grep -q '^macopenvm-agent:' "$target/etc/$file"
            printf '1\n' >"$target$state/before/$file.present"
            account_hash "$target/etc/$file" >"$target$state/before/$file.hash"
            stat -c '%a:%u:%g' "$target/etc/$file" >"$target$state/before/$file.mode"
        else printf '0\n' >"$target$state/before/$file.present"; fi
    done
    printf '%s\n' "$marker" >"$target/etc/macopenvm-agent-unrelated-sentinel"
    [ -d "$target/usr/local/sbin" ] && [ ! -L "$target/usr/local/sbin" ]
    [ ! -e "$target/usr/local/sbin/macopenvm-agent-install-lab" ]
    cp "$0" "$target/usr/local/sbin/macopenvm-agent-install-lab"
    chmod 700 "$target/usr/local/sbin/macopenvm-agent-install-lab"
    cat >"$target/etc/local.d/macopenvm-agent-install.start" <<'HOOK'
#!/bin/sh
/usr/local/sbin/macopenvm-agent-install-lab boot </dev/null >/dev/hvc0 2>&1 &
exit 0
HOOK
    chmod 700 "$target/etc/local.d/macopenvm-agent-install.start"
    printf '1\n' >"$target$state/next-boot"
    sync; umount "$target"; target=
    fact prepared 1
    phase=complete
    exit 0
fi

[ "$mode" = boot ] && [ "$#" = 1 ]
plain "$state/config"
marker=$(sed -n 1p "$state/config"); vm_id=$(sed -n 2p "$state/config")
pin=$(sed -n 3p "$state/config"); root_uuid=$(sed -n 4p "$state/config"); esp_uuid=$(sed -n 5p "$state/config")
printf '%s\n' "$marker" | grep -Eq '^mvo-agent-install-[0-9a-f]{32}$'
uuid_ok "$vm_id"; uuid_ok "$root_uuid"
printf '%s\n' "$pin" | grep -Eq '^[0-9a-f]{64}$'
boot=$(cat "$state/next-boot")
[ "$boot" = 1 ] || [ "$boot" = 2 ] || [ "$boot" = 3 ]
marker=$marker.boot$boot
trap finish EXIT
deadline=$(($(cut -d. -f1 /proc/uptime) + 150))
phase=normal-installed-boot
[ "$(uname -r)" = 6.18.55-0-virt ]
[ "$(get_uuid /dev/vda2)" = "$root_uuid" ] && [ "$(get_uuid /dev/vda1)" = "$esp_uuid" ]
awk '$1=="/dev/vda2" && $2=="/" && $3=="ext4" && $4 ~ /(^|,)rw(,|$)/ {ok=1} END {exit !ok}' /proc/mounts
while [ ! -e /run/openrc/started/local ]; do bounded_wait; sleep 1; done
modprobe vmw_vsock_virtio_transport
fact normalRoot 1
if [ "$boot" = 1 ] || [ "$boot" = 3 ]; then
    if [ "$boot" = 3 ]; then
        phase=removed-reservation-before-reenroll
        removed_installation
        fact reservationRemovedBeforeReenroll 1
    fi
    for module in xhci_hcd xhci_pci scsi_mod sd_mod usb_storage isofs; do
        case "$module" in
            xhci_hcd) driver=xhciHcd; phase=support-load-xhci-hcd;;
            xhci_pci) driver=xhciPci; phase=support-load-xhci-pci;;
            scsi_mod) driver=scsiMod; phase=support-load-scsi-mod;;
            sd_mod) driver=sdMod; phase=support-load-sd-mod;;
            usb_storage) driver=usbStorage; phase=support-load-usb-storage;;
            isofs) driver=isofs; phase=support-load-isofs;;
        esac
        modprobe "$module"
        if [ -d "/sys/module/$module" ]; then fact "supportDriver.$driver.present" 1;
        else fact "supportDriver.$driver.present" 0; fi
    done
    fact supportDrivers 1
    phase=support-device-wait
    fact support.waitBound 20
    support_facts initial
    support_deadline=$(($(cut -d. -f1 /proc/uptime) + 20))
    while [ ! -b /dev/sda ] || [ ! -e /sys/class/block/sda/ro ]; do
        bounded_wait
        if [ "$(cut -d. -f1 /proc/uptime)" -ge "$support_deadline" ]; then
            phase=support-device-wait-timeout
            support_facts timeout
            if [ ! -e /sys/class/block/sda ]; then fact support.waitFailure sysfsAbsent;
            elif [ ! -b /dev/sda ]; then fact support.waitFailure deviceNodeAbsent;
            else fact support.waitFailure roAttributeAbsent; fi
            exit 1
        fi
        sleep 1
    done
    phase=support-device-admission
    support_facts ready
    [ "$(ls /sys/class/block | grep '^sd')" = sda ]
    [ "$(cat /sys/class/block/sda/ro)" = 1 ]
    phase=support-usb-lineage
    case "$(readlink -f /sys/class/block/sda/device)" in */usb[0-9]*/*) ;; *) exit 72;; esac
    phase=support-iso-identity
    blkid /dev/sda | grep -q 'TYPE="iso9660"'
    blkid /dev/sda | grep -q 'LABEL="MVO_AGENT_INSTALL"'
    fact supportReadOnly 1
    phase=carrier-readonly-mount
    work=/run/macopenvm-agent-install-lab
    mkdir -m 700 "$work" "$work/media" "$work/payload" "$work/enrollment"
    # Select the inspected Joliet tree, matching the previously proved support-media recipe.
    mount -t iso9660 -o ro,norock /dev/sda "$work/media"
    awk -v destination="$work/media" '$1=="/dev/sda" && $2==destination && $3=="iso9660" && $4 ~ /(^|,)ro(,|$)/ && $4 ~ /(^|,)norock(,|$)/ && $4 !~ /(^|,)nojoliet(,|$)/ {ok=1} END {exit !ok}' /proc/mounts
    fact carrierJolietSelected 1
    phase=carrier-public-payload-catalog
    [ -d "$work/media/payload" ] && [ ! -L "$work/media/payload" ]
    for expected in SHA256SUMS agent initd setup.sh; do
        if [ -e "$work/media/payload/$expected" ]; then fact "carrierPayload.$expected" present;
        else fact "carrierPayload.$expected" absent; fi
    done
    phase=carrier-manifest-shape
    carrier_file "$work/media/payload/SHA256SUMS" 512
    fact carrierManifest.uid "$(stat -c %u "$work/media/payload/SHA256SUMS")"
    fact carrierManifest.mode "$(stat -c %a "$work/media/payload/SHA256SUMS")"
    fact carrierManifest.bytes "$(stat -c %s "$work/media/payload/SHA256SUMS")"
    fact carrierManifest.links "$(stat -c %h "$work/media/payload/SHA256SUMS")"
    phase=carrier-manifest-pin
    [ "$(sha256sum "$work/media/payload/SHA256SUMS" | cut -d' ' -f1)" = "$pin" ]
    phase=carrier-manifest-canonical
    awk 'NR==1 {name="agent"} NR==2 {name="initd"} NR==3 {name="setup.sh"}
      NR>3 || length($1)!=64 || $1 !~ /^[0-9a-f]+$/ || $0 != $1 "  " name {bad=1}
      END {exit bad || NR!=3}' "$work/media/payload/SHA256SUMS"
    fact signedCarrierManifest 1
    phase=carrier-payload-shape
    carrier_file "$work/media/payload/agent" 16777216
    carrier_file "$work/media/payload/initd" 16384
    carrier_file "$work/media/payload/setup.sh" 65536
    for file in SHA256SUMS agent initd setup.sh; do cp "$work/media/payload/$file" "$work/payload/$file"; done
    phase=staged-signed-payload
    for file in SHA256SUMS agent initd setup.sh; do plain "$work/payload/$file"; done
    [ "$(sha256sum "$work/payload/SHA256SUMS" | cut -d' ' -f1)" = "$pin" ]
    (cd "$work/payload" && sha256sum -c SHA256SUMS >/dev/null 2>&1)
    fact payloadBytesVerified 1
    phase=private-enrollment-copy
    [ -d "$work/media/enrollment" ] && [ ! -L "$work/media/enrollment" ]
    for file in cert.pem key.pem ca.pem; do carrier_file "$work/media/enrollment/$file" 65536; done
    carrier_file "$work/media/enrollment/vm-id" 37
    for file in cert.pem key.pem ca.pem vm-id; do cp "$work/media/enrollment/$file" "$work/enrollment/$file"; chmod 600 "$work/enrollment/$file"; done
    [ "$(cat "$work/enrollment/vm-id")" = "$vm_id" ]
    for parent in /usr/local /usr/local/libexec; do
        case "$parent" in /usr/local) label=localParent;; /usr/local/libexec) label=libexecParent;; esac
        if [ -e "$parent" ] || [ -L "$parent" ]; then
            [ -d "$parent" ] && [ ! -L "$parent" ]
            fact "$label.present" 1
            fact "$label.uid" "$(stat -c %u "$parent")"
            fact "$label.mode" "$(stat -c %a "$parent")"
        else fact "$label.present" 0; fi
    done
    if [ "$boot" = 1 ]; then
        phase=signed-pinned-install
        run_setup install "$work/payload/setup.sh" install --payload "$work/payload" --manifest-sha256 "$pin" --enrollment "$work/enrollment"
    else
        phase=signed-pinned-reenrollment
        # Only compare the public certificate privately; never emit a key fingerprint.
        [ "$(sha256sum "$work/enrollment/cert.pem" | cut -d' ' -f1)" != "$(awk '$1=="cert.pem" {print $2}' "$state/enrollment-before")" ]
        run_setup reenroll "$work/payload/setup.sh" reinstall --payload "$work/payload" --manifest-sha256 "$pin" --vm-id "$vm_id" --enrollment "$work/enrollment"
    fi
    phase=unmount-carrier
    umount "$work/media"
    phase=private-enrollment-cleanup
    for file in cert.pem key.pem ca.pem vm-id; do rm "$work/enrollment/$file"; done
    rmdir "$work/enrollment"
    phase=wait-service-ready
    wait_ready
    phase=service-facts
    if [ "$boot" = 3 ]; then
        process_facts reenrolled
        reservation_state installed
        fact reservationInstalledAfterReenroll 1
        [ "$(sha256sum /etc/macopenvm-agent/cert.pem | cut -d' ' -f1)" != "$(awk '$1=="cert.pem" {print $2}' "$state/enrollment-before")" ]
        fact freshEnrollmentDistinct 1
        accounts_preserved
        fact accountsPreserved 1; fact ready 1
        phase=healthy-fresh-enrollment
        wait_health 1
        sleep 2; bounded_wait
        phase=reenrollment-owned-uninstall
        run_setup reenrollRemoveUninstall /usr/local/libexec/macopenvm-agent/setup.sh uninstall --remove-credentials
        removed_installation
        fact accountsPreservedAfterUninstall 1; fact sentinelPreserved 1; fact accountLockedNonlogin 1
        fact reservationRemovedAfterReenroll 1; fact uninstalled 1
        # Attempt eight is the last admitted host request; no ninth refusal is claimed.
        printf 'complete\n' >"$state/next-boot"
        phase=complete
        exit 0
    fi
    process_facts started
    first_pid=$pid
    phase=accounts-preserved
    accounts_preserved
    enrollment_facts >"$state/enrollment-before"
    reservation_state installed
    fact accountsPreserved 1; fact ready 1
    phase=healthy-reconnect
    wait_health 2
    sleep 2; bounded_wait
    process_facts reconnected
    [ "$pid" = "$first_pid" ]
    accounts_preserved; fact reconnect 1
    phase=retained-credential-uninstall
    run_setup keepUninstall /usr/local/libexec/macopenvm-agent/setup.sh uninstall
    ! pidof macopenvm-agent >/dev/null 2>&1
    enrollment_preserved
    accounts_preserved
    fact keptCredentials 1
    phase=retained-uninstall-refusal-window
    sleep 15; bounded_wait
    phase=owned-reinstall
    run_setup reinstall "$work/payload/setup.sh" reinstall --payload "$work/payload" --manifest-sha256 "$pin" --vm-id "$vm_id" --reuse-credentials
    wait_ready
    process_facts reinstalled
    [ "$pid" != "$first_pid" ]
    enrollment_preserved
    accounts_preserved
    fact enrollmentPreservedAfterReinstall 1
    fact reinstalledReady 1
    wait_health 1
    sleep 2; bounded_wait
    printf '2\n' >"$state/next-boot"
    phase=complete
    exit 0
fi

[ ! -e /dev/sda ] && [ ! -e /dev/sdb ]
fact discsAbsent 1
wait_ready; process_facts cold
enrollment_preserved
fact enrollmentPreservedOnColdBoot 1
accounts_preserved; fact accountsPreserved 1; fact ready 1
phase=healthy-cold-boot
wait_health 1
sleep 2; bounded_wait
phase=service-restart
rc-service macopenvm-agent stop >/dev/null 2>&1
! pidof macopenvm-agent >/dev/null 2>&1
owned_log; : >"$log"
rc-service macopenvm-agent start >/dev/null 2>&1
wait_ready; process_facts restarted
enrollment_preserved
fact enrollmentPreservedAfterRestart 1
fact restartReady 1
wait_health 1
sleep 2; bounded_wait
phase=owned-uninstall
run_setup removeUninstall /usr/local/libexec/macopenvm-agent/setup.sh uninstall --remove-credentials
removed_installation
fact accountsPreservedAfterUninstall 1; fact sentinelPreserved 1; fact accountLockedNonlogin 1
fact reservationRemoved 1; fact uninstalled 1
phase=post-uninstall-refusal-window
sleep 15
bounded_wait
printf '3\n' >"$state/next-boot"
phase=complete
