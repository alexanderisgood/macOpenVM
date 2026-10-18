#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Fixed LAB-only orchestration on a freshly copied private root. Never a product autorun.
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
umask 077
mode=$1
state=/var/lib/macopenvm-agent-upgrade-lab
log=/run/macopenvm-agent.log
program=/usr/local/libexec/macopenvm-agent/macopenvm-agent
retirement_id=
manager_limit=65536
rp=/usr/local/libexec/macopenvm-agent
rs=/var/lib/macopenvm-agent
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
retirement_uuid_ok() {
    uuid_ok "$1" && [ "$(printf '%s' "$1" | tr A-F a-f)" = "$1" ] && [ "$1" != 00000000-0000-0000-0000-000000000000 ]
}
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
    stat -c '%d:%i:%a:%u:%g' /etc/macopenvm-agent
    for file in cert.pem key.pem ca.pem vm-id; do
        path=/etc/macopenvm-agent/$file
        [ -f "$path" ] && [ ! -L "$path" ] && [ "$(stat -c %h "$path")" = 1 ]
        printf '%s %s %s\n' "$file" "$(sha256sum "$path" | cut -d' ' -f1)" "$(stat -c '%d:%i:%a:%u:%g:%h' "$path")"
    done
}
enrollment_preserved() {
    # Private comparison only: never emit credential fingerprints into transcripts.
    [ "$(enrollment_facts)" = "$(cat "$state/enrollment-before")" ]
}
run_setup() {
    setup_label=$1
    shift
    case "$setup_label" in install|upgrade|rollback|retire) ;; *) return 1;; esac
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
    expected=$1; version=$2
    case "$version" in 0.1.0|0.1.1) ;; *) return 1;; esac
    while [ "$(grep -Fxc "mvo.agent-tls.health-complete version=$version architecture=arm64" "$log" || true)" -lt "$expected" ]; do
        bounded_wait; sleep 1
    done
    [ "$(stat -c %s "$log")" -le 65536 ]
}

generation_check() {
    current_pin=$1; previous_pin=$2; directory=$3
    [ -d "$directory" ] && [ ! -L "$directory" ]
    [ "$(stat -c '%a:%u:%g' "$directory")" = 700:0:0 ]
    [ "$(ls -A1 "$directory")" = "$(printf 'enrollment.sha256\ngeneration\nowner\npayload.sha256')" ]
    for file in owner payload.sha256 enrollment.sha256 generation; do
        plain "$directory/$file"; [ "$(stat -c '%a:%h' "$directory/$file")" = 600:1 ]
        [ "$(stat -c %s "$directory/$file")" -gt 0 ] && [ "$(stat -c %s "$directory/$file")" -le 1024 ]
    done
    [ "$(sha256sum "$directory/payload.sha256" | cut -d' ' -f1)" = "$current_pin" ]
    expected=$(printf 'macopenvm-agent-owned-v2\nmanifest-sha256=%s\nservice-uid=%s\nservice-gid=%s\n' "$current_pin" "$(id -u macopenvm-agent)" "$(id -g macopenvm-agent)")
    [ "$(cat "$directory/owner")" = "$expected" ] && [ "$(awk 'END{print NR}' "$directory/owner")" = 4 ]
    expected=$(printf 'macopenvm-agent-generation-v2\nvm-id=%s\ncurrent=%s\nprevious=%s\nmanager=%s\ninitd=%s\n' \
        "$(printf '%s' "$vm_id" | tr A-F a-f)" "$current_pin" "$previous_pin" \
        "$(sha256sum /usr/local/libexec/macopenvm-agent/setup.sh | cut -d' ' -f1)" \
        "$(sha256sum /etc/init.d/macopenvm-agent | cut -d' ' -f1)")
    [ "$(cat "$directory/generation")" = "$expected" ] && [ "$(awk 'END{print NR}' "$directory/generation")" = 6 ]
    (cd /etc/macopenvm-agent && sha256sum -c "$directory/enrollment.sha256" >/dev/null 2>&1)
}
program_check() {
    directory=$1; manifest=$2
    [ -d "$directory" ] && [ ! -L "$directory" ] && [ "$(stat -c '%a:%u:%g' "$directory")" = 755:0:0 ]
    [ "$(ls -A1 "$directory")" = "$(printf 'macopenvm-agent\nsetup.sh')" ]
    for entry in macopenvm-agent:1 setup.sh:3; do
        file=${entry%:*}; line=${entry#*:}; plain "$directory/$file"
        [ "$(stat -c '%a:%h' "$directory/$file")" = 755:1 ]
        [ "$(sha256sum "$directory/$file" | cut -d' ' -f1)" = "$(sed -n "$line"'s/ .*//p' "$manifest")" ]
    done
}
owned_snapshot() {
    for directory in /usr/local/libexec/macopenvm-agent /var/lib/macopenvm-agent; do
        stat -c '%d:%i:%a:%u:%g' "$directory" || return 1
        for file in "$directory"/*; do sha256sum "$file" || return 1; stat -c '%d:%i:%a:%u:%g:%h' "$file" || return 1; done
    done
}
failed_snapshot() {
    for directory in /usr/local/libexec/macopenvm-agent.failed /var/lib/macopenvm-agent.failed; do
        stat -c '%d:%i:%a:%u:%g' "$directory" || return 1
        for file in "$directory"/*; do sha256sum "$file" || return 1; stat -c '%d:%i:%a:%u:%g:%h' "$file" || return 1; done
    done
}
file_hash() {
    hash_result=$(sha256sum "$1") || return 1
    hash_result=${hash_result%% *}
    [ "${#hash_result}" = 64 ] && printf '%s\n' "$hash_result" | grep -Eq '^[0-9a-f]+$' || return 1
    printf '%s\n' "$hash_result"
}
state_hash() {
    hash_lines=
    for component in owner payload.sha256 enrollment.sha256 generation; do
        component_hash=$(file_hash "$1/$component") || return 1
        hash_lines=$hash_lines$component_hash'  '$component'
'
    done
    hash_result=$(printf '%s' "$hash_lines" | sha256sum) || return 1
    printf '%s\n' "${hash_result%% *}"
}
transaction_check() {
    operation=$1; source_pin=$2; target_pin=$3; source_state=$4; target_state=$5; journal=$6
    plain "$journal"
    [ "$(stat -c '%a:%h' "$journal")" = 600:1 ]
    [ "$(stat -c %s "$journal")" -le 2048 ]
    expected=$(printf 'macopenvm-agent-transaction-v2\noperation=%s\nvm-id=%s\nsource=%s\ntarget=%s\nmanager=%s\nuid=%s\ngid=%s\nreservation=%s\nsource-state=%s\ntarget-state=%s\nphase=complete\n' \
        "$operation" "$(printf '%s' "$vm_id" | tr A-F a-f)" "$source_pin" "$target_pin" \
        "$(file_hash /usr/local/libexec/macopenvm-agent/setup.sh)" "$(id -u macopenvm-agent)" "$(id -g macopenvm-agent)" \
        "$(file_hash /var/lib/macopenvm-agent-account/record)" "$(state_hash "$source_state")" "$(state_hash "$target_state")")
    [ "$(cat "$journal")" = "$expected" ] && [ "$(awk 'END{print NR}' "$journal")" = 12 ]
}
account_full_snapshot() {
    for account_file in passwd shadow group gshadow; do
        if [ -e "/etc/$account_file" ] || [ -L "/etc/$account_file" ]; then
            plain "/etc/$account_file"; [ "$(stat -c %h "/etc/$account_file")" = 1 ]
            printf '%s present\n' "$account_file"
            file_hash "/etc/$account_file" || return 1
            stat -c '%d:%i:%a:%u:%g:%h' "/etc/$account_file" || return 1
        else printf '%s absent\n' "$account_file"; fi
    done
}
reservation_rows_match() {
    reservation=/var/lib/macopenvm-agent-account/record
    plain "$reservation"; [ "$(stat -c '%a:%h' "$reservation")" = 600:1 ]
    [ "$(sed -n 1p "$reservation")" = macopenvm-agent-account-v2 ]
    [ "$(sed -n 2p "$reservation")" = "vm-id=$(printf '%s' "$vm_id" | tr A-F a-f)" ]
    [ "$(sed -n 3p "$reservation")" = "service-uid=$(id -u macopenvm-agent)" ]
    [ "$(sed -n 4p "$reservation")" = "service-gid=$(id -g macopenvm-agent)" ]
    [ "$(sed -n 8p "$reservation")" = credentials=installed ]
    [ "$(awk 'END{print NR}' "$reservation")" = 12 ]
    for entry in passwd:5 shadow:6 group:7; do
        account_file=${entry%:*}; line=${entry#*:}
        account_row=$(grep '^macopenvm-agent:' "/etc/$account_file")
        [ "${#account_row}" -le 512 ] && [ "$(printf '%s\n' "$account_row" | wc -l | tr -d ' ')" = 1 ]
        row_digest=$(printf '%s\n' "$account_row" | sha256sum)
        [ "${row_digest%% *}" = "$(sed -n "$line"'s/^[^=]*=//p' "$reservation")" ]
    done
}
identity_preserved() {
    accounts_preserved; enrollment_preserved
    [ "$(account_full_snapshot)" = "$(cat "$state/accounts-after-a")" ]
    reservation_rows_match
    grep -q '^macopenvm-agent:!:' /etc/shadow
    grep -q '^macopenvm-agent:[^:]*:[0-9]*:[0-9]*:[^:]*:/nonexistent:/sbin/nologin$' /etc/passwd
    cmp -s /var/lib/macopenvm-agent-account/record "$state/reservation-before"
    [ "$(id -u macopenvm-agent):$(id -g macopenvm-agent)" = "$(cat "$state/service-identity")" ]
}
retired_snapshot() {
  tree=$1
  [ -d "$tree" ] && [ ! -L "$tree" ] || return 1
  stat -c '%d:%i:%a:%u:%g' "$tree" || return 1
  for file in "$tree"/*; do
      plain "$file" && [ "$(stat -c %h "$file")" = 1 ] || return 1
      printf '%s\n' "${file##*/}"
      file_hash "$file" || return 1
      stat -c '%d:%i:%a:%u:%g:%h' "$file" || return 1
  done
}
cohort_hash() {
  tree=$1
  lines=
  for file in "$tree"/*; do
      value=$(file_hash "$file") || return 1
      lines=$lines$value'  '${file##*/}'
'
  done
  value=$(printf '%s' "$lines" | sha256sum) || return 1
  printf '%s\n' "${value%% *}"
}
retirement_before() {
  for name in retired-program-before retired-state-before retired-cohort-before receipt-expected kernel-lock-before; do
      [ ! -e "$state/$name" ] && [ ! -L "$state/$name" ]
  done
  [ "$(ls -A1 $rs.install-lock)" = "$(printf 'previous-transaction\ntransaction')" ]
  retired_snapshot $rp.failed >"$state/retired-program-before"
  retired_snapshot $rs.failed >"$state/retired-state-before"
  retired_snapshot $rs.install-lock >"$state/retired-cohort-before"
  stat -c '%d:%i:%a:%u:%g:%h:%s' $rs.kernel-lock >"$state/kernel-lock-before"
  current_state=$(state_hash $rs)
  failed_state=$(state_hash $rs.failed)
  cohort=$(cohort_hash $rs.install-lock)
  manager=$(file_hash $rp/setup.sh)
  initd=$(file_hash /etc/init.d/macopenvm-agent)
  reservation=$(file_hash $rs-account/record)
  printf 'macopenvm-agent-retirement-v1\nvm-id=%s\nretirement-id=%s\ncurrent=%s\nfailed=%s\nmanager=%s\ninitd=%s\nuid=%s\ngid=%s\nreservation=%s\ncurrent-state=%s\nfailed-state=%s\ncohort=%s\ncurrent-program-inode=%s\ncurrent-state-inode=%s\nfailed-program-inode=%s\nfailed-state-inode=%s\ncohort-inode=%s\nphase=complete\n' \
      "$(printf '%s' "$vm_id" | tr A-F a-f)" "$retirement_id" "$pin_a" "$pin_b" "$manager" "$initd" \
      "$(id -u macopenvm-agent)" "$(id -g macopenvm-agent)" "$reservation" "$current_state" "$failed_state" "$cohort" \
      "$(stat -c '%d:%i' $rp)" "$(stat -c '%d:%i' $rs)" \
      "$(stat -c '%d:%i' $rp.failed)" "$(stat -c '%d:%i' $rs.failed)" \
      "$(stat -c '%d:%i' $rs.install-lock)" >"$state/receipt-expected"
}
retirement_check() {
  program_archive=$rp.retired/$retirement_id
  state_archive=$rs.retired/$retirement_id
  for parent in $rp.retired $rs.retired; do
      [ -d "$parent" ] && [ ! -L "$parent" ] && [ "$(stat -c '%a:%u:%g' "$parent")" = 700:0:0 ]
      [ "$(ls -A1 "$parent")" = "$retirement_id" ]
  done
  for tree in "$program_archive" "$state_archive" "$state_archive/journals" "$state_archive/retirement"; do
      [ -d "$tree" ] && [ ! -L "$tree" ] && [ "$(stat -c '%a:%u:%g' "$tree")" = 700:0:0 ]
  done
  [ "$(ls -A1 "$program_archive")" = program ]
  [ "$(ls -A1 "$state_archive")" = "$(printf 'journals\nretirement\nstate')" ]
  [ "$(ls -A1 "$state_archive/retirement")" = "$(printf 'confirmation\nrecord')" ]
  for file in record confirmation; do
      plain "$state_archive/retirement/$file"
      [ "$(stat -c '%a:%h' "$state_archive/retirement/$file")" = 600:1 ]
      [ "$(stat -c %s "$state_archive/retirement/$file")" -le 2048 ]
      cmp -s "$state/receipt-expected" "$state_archive/retirement/$file"
  done
  for path in $rp.failed $rs.failed \
      $rp.previous $rs.previous \
      $rs.install-lock $rs.retirement $rs.retirement.next; do
      [ ! -e "$path" ] && [ ! -L "$path" ]
  done
  generation_check "$pin_a" - $rs
  program_check $rp $rs/payload.sha256
  [ "$(owned_snapshot)" = "$(cat "$state/a-before")" ]
  generation_check "$pin_b" "$pin_a" "$state_archive/state"
  program_check "$program_archive/program" "$state_archive/state/payload.sha256"
  [ "$(retired_snapshot "$program_archive/program")" = "$(cat "$state/retired-program-before")" ]
  [ "$(retired_snapshot "$state_archive/state")" = "$(cat "$state/retired-state-before")" ]
  [ "$(retired_snapshot "$state_archive/journals")" = "$(cat "$state/retired-cohort-before")" ]
  transaction_check rollback "$pin_b" "$pin_a" "$state_archive/state" $rs "$state_archive/journals/transaction"
  transaction_check upgrade "$pin_a" "$pin_b" $rs "$state_archive/state" "$state_archive/journals/previous-transaction"
  plain $rs.kernel-lock
  [ "$(stat -c '%d:%i:%a:%u:%g:%h:%s' $rs.kernel-lock)" = "$(cat "$state/kernel-lock-before")" ]
  identity_preserved
  fact retirement.id "$retirement_id"
  fact retirementConfirmed 1
  fact currentAPreserved 1
  fact archivedBPreserved 1
  fact cohortPreserved 1
  fact retirementKernelLockPreserved 1
}
retirement_stopped() {
  if rc-service macopenvm-agent status >/dev/null 2>&1; then return 1; else stop_status=$?; fi
  [ "$stop_status" = 3 ]
  if service_pid=$(pidof macopenvm-agent); then return 1; else pid_status=$?; fi
  [ "$pid_status" = 1 ] && [ -z "$service_pid" ]
  (exec 9<>$rs.kernel-lock
   flock -n 9
   [ "$(stat -L -c '%d:%i' /dev/fd/9)" = "$(stat -c '%d:%i' $rs.kernel-lock)" ])
  fact serviceStopped 1
}
if [ "$mode" = prepare ]; then
    [ "$#" = 7 ] || [ "$#" = 9 ]
    marker=$2 vm_id=$3 pin_a=$4 pin_b=$5 root_uuid=$6 esp_uuid=$7
    if [ "$#" = 9 ]; then
        [ "$8" = retirement-v1 ]; retirement_id=$9
        retirement_uuid_ok "$retirement_id"
        manager_limit=131072
    fi
    printf '%s\n' "$marker" | grep -Eq '^mvo-agent-upgrade-[0-9a-f]{32}$'
    uuid_ok "$vm_id"; uuid_ok "$root_uuid"
    printf '%s\n' "$pin_b" | grep -Eq '^[0-9a-f]{64}$'
    [ "$pin_a" != "$pin_b" ]
    printf '%s\n' "$pin_a" | grep -Eq '^[0-9a-f]{64}$'
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
    backup=$hook.disabled-${marker#mvo-agent-upgrade-}
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
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$marker" "$vm_id" "$pin_a" "$pin_b" "$root_uuid" "$esp_uuid" >"$target$state/config"
    if [ -n "$retirement_id" ]; then printf 'retirement-v1\n%s\n' "$retirement_id" >>"$target$state/config"; fi
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
    [ ! -e "$target/usr/local/sbin/macopenvm-agent-upgrade-lab" ]
    cp "$0" "$target/usr/local/sbin/macopenvm-agent-upgrade-lab"
    chmod 700 "$target/usr/local/sbin/macopenvm-agent-upgrade-lab"
    cat >"$target/etc/local.d/macopenvm-agent-upgrade.start" <<'HOOK'
#!/bin/sh
/usr/local/sbin/macopenvm-agent-upgrade-lab boot </dev/null >/dev/hvc0 2>&1 &
exit 0
HOOK
    chmod 700 "$target/etc/local.d/macopenvm-agent-upgrade.start"
    printf '1\n' >"$target$state/next-boot"
    sync; umount "$target"; target=
    fact prepared 1
    phase=complete
    exit 0
fi

[ "$mode" = boot ] && [ "$#" = 1 ]
plain "$state/config"
marker=$(sed -n 1p "$state/config"); vm_id=$(sed -n 2p "$state/config")
pin_a=$(sed -n 3p "$state/config"); pin_b=$(sed -n 4p "$state/config")
root_uuid=$(sed -n 5p "$state/config"); esp_uuid=$(sed -n 6p "$state/config")
case "$(awk 'END{print NR}' "$state/config")" in
    6) ;;
    8) [ "$(sed -n 7p "$state/config")" = retirement-v1 ]
       retirement_id=$(sed -n 8p "$state/config"); retirement_uuid_ok "$retirement_id"
       manager_limit=131072 ;;
    *) exit 1 ;;
esac
printf '%s\n' "$marker" | grep -Eq '^mvo-agent-upgrade-[0-9a-f]{32}$'
uuid_ok "$vm_id"; uuid_ok "$root_uuid"
for pin in "$pin_a" "$pin_b"; do printf '%s\n' "$pin" | grep -Eq '^[0-9a-f]{64}$'; done
boot=$(cat "$state/next-boot"); case "$boot" in 1|2|3) ;; *) exit 1;; esac
marker=$marker.boot$boot; trap finish EXIT
deadline=$(($(cut -d. -f1 /proc/uptime) + 150))
phase=normal-installed-boot
[ "$(uname -r)" = 6.18.55-0-virt ]
[ "$(get_uuid /dev/vda2)" = "$root_uuid" ] && [ "$(get_uuid /dev/vda1)" = "$esp_uuid" ]
awk '$1=="/dev/vda2" && $2=="/" && $3=="ext4" && $4 ~ /(^|,)rw(,|$)/ {ok=1} END {exit !ok}' /proc/mounts
while [ ! -e /run/openrc/started/local ]; do bounded_wait; sleep 1; done
modprobe vmw_vsock_virtio_transport
fact normalRoot 1
if [ "$boot" = 1 ]; then
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
    # Emit only bounded public type/label values, never raw probe output or enrollment.
    support_probe=$(blkid /dev/sda) || { fact support.probe failed; exit 1; }
    support_type=$(printf '%s\n' "$support_probe" | sed -n 's/.* TYPE="\([A-Za-z0-9_-]*\)".*/\1/p')
    support_label=$(printf '%s\n' "$support_probe" | sed -n 's/.* LABEL="\([A-Za-z0-9_-]*\)".*/\1/p')
    [ "${#support_type}" -le 32 ] && [ "${#support_label}" -le 32 ]
    fact support.type "${support_type:-absent}"
    fact support.label "${support_label:-absent}"
    [ "$support_type" = iso9660 ]
    [ "$support_label" = MVO_AGENT_ABA ]
    fact supportReadOnly 1
    phase=carrier-readonly-mount
    work=/run/macopenvm-agent-upgrade-lab
    mkdir -m 700 "$work" "$work/media" "$work/payload-a" "$work/payload-b" "$work/enrollment"
    # Select the inspected Joliet tree, matching the previously proved support-media recipe.
    mount -t iso9660 -o ro,norock /dev/sda "$work/media"
    awk -v destination="$work/media" '$1=="/dev/sda" && $2==destination && $3=="iso9660" && $4 ~ /(^|,)ro(,|$)/ && $4 ~ /(^|,)norock(,|$)/ && $4 !~ /(^|,)nojoliet(,|$)/ {ok=1} END {exit !ok}' /proc/mounts
    fact carrierJolietSelected 1
    phase=staged-approved-generations
    for label in a b; do
        if [ "$label" = a ]; then approved_pin=$pin_a; else approved_pin=$pin_b; fi
        [ "$(ls -A1 "$work/media/payload-$label")" = "$(printf 'SHA256SUMS\nagent\ninitd\nsetup.sh')" ]
        for entry in agent:16777216 initd:16384 setup.sh:$manager_limit SHA256SUMS:512; do
            file=${entry%:*}; limit=${entry#*:}
            carrier_file "$work/media/payload-$label/$file" "$limit"
            cp "$work/media/payload-$label/$file" "$work/payload-$label/$file"
            chmod 600 "$work/payload-$label/$file"
        done
        [ "$(sha256sum "$work/payload-$label/SHA256SUMS" | cut -d' ' -f1)" = "$approved_pin" ]
        (cd "$work/payload-$label" && sha256sum -c SHA256SUMS >/dev/null 2>&1)
    done
    cmp -s "$work/payload-a/setup.sh" "$work/payload-b/setup.sh"
    cmp -s "$work/payload-a/initd" "$work/payload-b/initd"
    phase=private-enrollment-copy
    [ "$(ls -A1 "$work/media/enrollment")" = "$(printf 'ca.pem\ncert.pem\nkey.pem\nvm-id')" ]
    for file in cert.pem key.pem ca.pem vm-id; do
        carrier_file "$work/media/enrollment/$file" 65536
        cp "$work/media/enrollment/$file" "$work/enrollment/$file"; chmod 600 "$work/enrollment/$file"
    done
    [ "$(cat "$work/enrollment/vm-id")" = "$vm_id" ]
    umount "$work/media"
    phase=install-a
    run_setup install "$work/payload-a/setup.sh" install --payload "$work/payload-a" --manifest-sha256 "$pin_a" --enrollment "$work/enrollment"
    for file in cert.pem key.pem ca.pem vm-id; do rm "$work/enrollment/$file"; done
    rmdir "$work/enrollment"
    wait_ready; process_facts initialA
    generation_check "$pin_a" - /var/lib/macopenvm-agent
    program_check /usr/local/libexec/macopenvm-agent /var/lib/macopenvm-agent/payload.sha256
    enrollment_facts >"$state/enrollment-before"
    cp /var/lib/macopenvm-agent-account/record "$state/reservation-before"
    owned_snapshot >"$state/a-before"
    account_full_snapshot >"$state/accounts-after-a"
    reservation_rows_match
    fact ready 1; wait_health 1 0.1.0
    phase=upgrade-b
    run_setup upgrade /usr/local/libexec/macopenvm-agent/setup.sh upgrade --vm-id "$vm_id" --expect-generation "$pin_a" --payload "$work/payload-b" --manifest-sha256 "$pin_b"
    wait_ready; process_facts upgradedB
    generation_check "$pin_b" "$pin_a" /var/lib/macopenvm-agent
    program_check /usr/local/libexec/macopenvm-agent /var/lib/macopenvm-agent/payload.sha256
    generation_check "$pin_a" - /var/lib/macopenvm-agent.previous
    program_check /usr/local/libexec/macopenvm-agent.previous /var/lib/macopenvm-agent.previous/payload.sha256
    [ "$(ls -A1 /var/lib/macopenvm-agent.install-lock)" = transaction ]
    transaction_check upgrade "$pin_a" "$pin_b" /var/lib/macopenvm-agent.previous /var/lib/macopenvm-agent /var/lib/macopenvm-agent.install-lock/transaction
    identity_preserved; fact upgradedReady 1; wait_health 1 0.1.1
    printf '2\n' >"$state/next-boot"
elif [ "$boot" = 2 ]; then
    [ "$(ls /sys/class/block | grep '^sd' || true)" = '' ]
    wait_ready; process_facts coldB
    generation_check "$pin_b" "$pin_a" /var/lib/macopenvm-agent
    identity_preserved; fact ready 1; wait_health 1 0.1.1
    phase=rollback-a
    run_setup rollback /usr/local/libexec/macopenvm-agent/setup.sh rollback --vm-id "$vm_id" --expect-generation "$pin_b" --generation-sha256 "$pin_a"
    wait_ready; process_facts rolledA
    generation_check "$pin_a" - /var/lib/macopenvm-agent
    program_check /usr/local/libexec/macopenvm-agent /var/lib/macopenvm-agent/payload.sha256
    generation_check "$pin_b" "$pin_a" /var/lib/macopenvm-agent.failed
    program_check /usr/local/libexec/macopenvm-agent.failed /var/lib/macopenvm-agent.failed/payload.sha256
    [ "$(owned_snapshot)" = "$(cat "$state/a-before")" ]
    failed_snapshot >"$state/b-failed-before"
    [ "$(ls -A1 /var/lib/macopenvm-agent.install-lock)" = "$(printf 'previous-transaction\ntransaction')" ]
    transaction_check rollback "$pin_b" "$pin_a" /var/lib/macopenvm-agent.failed /var/lib/macopenvm-agent /var/lib/macopenvm-agent.install-lock/transaction
    transaction_check upgrade "$pin_a" "$pin_b" /var/lib/macopenvm-agent /var/lib/macopenvm-agent.failed /var/lib/macopenvm-agent.install-lock/previous-transaction
    [ ! -e /usr/local/libexec/macopenvm-agent.previous ] && [ ! -e /var/lib/macopenvm-agent.previous ]
    identity_preserved; fact rollbackReady 1; wait_health 1 0.1.0
    if [ -n "$retirement_id" ]; then
        phase=retire-failed-b
        retirement_before
        run_setup retire /usr/local/libexec/macopenvm-agent/setup.sh retire-failed --vm-id "$vm_id" \
            --expect-generation "$pin_a" --generation-sha256 "$pin_b" --retirement-id "$retirement_id"
        retirement_stopped
        retirement_check
        retired_snapshot "$state_archive/retirement" >"$state/receipt-before"
    fi
    printf '3\n' >"$state/next-boot"
else
    [ "$(ls /sys/class/block | grep '^sd' || true)" = '' ]
    wait_ready; process_facts coldA
    generation_check "$pin_a" - /var/lib/macopenvm-agent
    program_check /usr/local/libexec/macopenvm-agent /var/lib/macopenvm-agent/payload.sha256
    [ "$(owned_snapshot)" = "$(cat "$state/a-before")" ]
    if [ -n "$retirement_id" ]; then
        phase=post-retirement-cold-a
        retirement_check
        [ "$(retired_snapshot "$state_archive/retirement")" = "$(cat "$state/receipt-before")" ]
    else
        generation_check "$pin_b" "$pin_a" /var/lib/macopenvm-agent.failed
        program_check /usr/local/libexec/macopenvm-agent.failed /var/lib/macopenvm-agent.failed/payload.sha256
        [ "$(failed_snapshot)" = "$(cat "$state/b-failed-before")" ]
        [ "$(ls -A1 /var/lib/macopenvm-agent.install-lock)" = "$(printf 'previous-transaction\ntransaction')" ]
        transaction_check rollback "$pin_b" "$pin_a" /var/lib/macopenvm-agent.failed /var/lib/macopenvm-agent /var/lib/macopenvm-agent.install-lock/transaction
        transaction_check upgrade "$pin_a" "$pin_b" /var/lib/macopenvm-agent /var/lib/macopenvm-agent.failed /var/lib/macopenvm-agent.install-lock/previous-transaction
    fi
    identity_preserved; fact ready 1; wait_health 1 0.1.0
    if [ -z "$retirement_id" ]; then fact failedBPreserved 1; fi
    printf 'complete\n' >"$state/next-boot"
fi
fact identityPreserved 1
fact accountsPreserved 1
phase=complete
exit 0
