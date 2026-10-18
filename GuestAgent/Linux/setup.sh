#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Experimental Alpine/OpenRC only. This is an explicit root operation, never an autorun hook.
# The caller must authenticate the publisher and approve the exact manifest out of band.
# A SHA256 pin checks those approved bytes; it is not itself a publisher signature.
set -eu
umask 077
LC_ALL=C
export LC_ALL
exec 3>&2 2>/dev/null
error_reported=no
trap 'status=$?; if [ "$status" -ne 0 ] && [ "$error_reported" = no ]; then printf "%s\n" "Experimental agent setup: Operation failed; partial state is preserved for explicit recovery." >&3; fi' 0

die() { error_reported=yes; printf '%s\n' "Experimental agent setup: $1" >&3; exit 1; }
usage() {
  printf '%s\n' \
    'Experimental Alpine/OpenRC agent setup' \
    'install --payload DIR --manifest-sha256 HEX --enrollment DIR' \
    'reinstall --payload DIR --manifest-sha256 HEX --vm-id UUID --reuse-credentials' \
    'reinstall --payload DIR --manifest-sha256 HEX --vm-id UUID --enrollment DIR' \
    'upgrade --vm-id UUID --expect-generation A --payload DIR --manifest-sha256 B' \
    'rollback --vm-id UUID --expect-generation B --generation-sha256 A' \
    'recover --vm-id UUID --expect-generation A --generation-sha256 B --resume' \
    'retire-failed --vm-id UUID --expect-generation A --generation-sha256 B --retirement-id UUID [--resume]' \
    'uninstall [--remove-credentials]' \
    'Interrupted staging/commits are preserved. Inspect owned state before explicit uninstall recovery.' \
    'Uninstall leaves the dedicated locked, nonlogin service account in place.'
}

action= payload= pin= enrollment= sysroot= command_dir= expected_vm= expected_generation= target_generation= remove_credentials=no reuse_credentials=no resume=no test_mode=no retirement_id=
while [ "$#" -gt 0 ]; do
  case "$1" in
    install|reinstall|uninstall|upgrade|rollback|recover|retire-failed) [ -z "$action" ] || die 'Specify one action.'; action=$1; shift ;;
    --payload|--manifest-sha256|--enrollment|--vm-id|--expect-generation|--generation-sha256|--retirement-id|--test-sysroot|--test-command-dir)
      [ "$#" -ge 2 ] || die 'An option value is missing.'
      case "$1" in
        --payload) [ -z "$payload" ] || die 'Duplicate option.'; payload=$2 ;;
        --manifest-sha256) [ -z "$pin" ] || die 'Duplicate option.'; pin=$2 ;;
        --enrollment) [ -z "$enrollment" ] || die 'Duplicate option.'; enrollment=$2 ;;
        --vm-id) [ -z "$expected_vm" ] || die 'Duplicate option.'; expected_vm=$2 ;;
        --expect-generation) [ -z "$expected_generation" ] || die 'Duplicate option.'; expected_generation=$2 ;;
        --generation-sha256) [ -z "$target_generation" ] || die 'Duplicate option.'; target_generation=$2 ;;
        --retirement-id) [ -z "$retirement_id" ] || die 'Duplicate option.'; retirement_id=$2 ;;
        --test-sysroot) [ -z "$sysroot" ] || die 'Duplicate option.'; sysroot=$2 ;;
        --test-command-dir) [ -z "$command_dir" ] || die 'Duplicate option.'; command_dir=$2 ;;
      esac
      shift 2 ;;
    --resume) [ "$resume" = no ] || die 'Duplicate option.'; resume=yes; shift ;;
    --remove-credentials) [ "$remove_credentials" = no ] || die 'Duplicate option.'; remove_credentials=yes; shift ;;
    --reuse-credentials) [ "$reuse_credentials" = no ] || die 'Duplicate option.'; reuse_credentials=yes; shift ;;
    --help) usage; exit 0 ;;
    *) die 'Unknown option.' ;;
  esac
done
[ -n "$action" ] || { usage; exit 1; }
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

safe_absolute() {
  [ "${#1}" -le 4096 ] && printf '%s\n' "$1" | awk '
    /^\/[A-Za-z0-9_.\/+@:-]+$/ && !/\/\// && !/\/(\.|\.\.)(\/|$)/ && !/\/$/ { ok=1 }
    END { exit !ok }' || die 'Use a bounded absolute path without ambiguous components.'
}
no_symlink_ancestors() {
  local rest current component
  [ "$1" != / ] || return 0
  safe_absolute "$1"
  rest=${1#/}; current=
  while [ -n "$rest" ]; do
    component=${rest%%/*}
    if [ "$rest" = "$component" ]; then rest=; else rest=${rest#*/}; fi
    current=$current/$component
    [ ! -L "$current" ] || die 'Symbolic links are not accepted.'
    if [ -e "$current" ] && [ -n "$rest" ]; then
      [ -d "$current" ] || die 'An ancestor is not a directory.'
    fi
  done
}
owner_is() {
  [ "$test_mode" = yes ] || [ "$(stat -c %u "$1")" = "$2" ] || die 'An owned path has an unexpected owner.'
}
plain_directory() {
  no_symlink_ancestors "$1"
  [ -d "$1" ] || die 'A required plain directory is absent.'
}
regular_bounded() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %h "$1")" = 1 ] || die 'Expected one plain regular file.'
  local size
  size=$(stat -c %s "$1")
  [ "$size" -gt 0 ] && [ "$size" -le "$2" ] || die 'A file exceeds its allowed size.'
}
expect_names() {
  [ "$(ls -A1 "$1")" = "$2" ] || die 'A directory contains unexpected entries.'
}
hash_of() {
  local value
  value=$(sha256sum "$1") || die 'An owned file could not be hashed.'
  value=${value%% *}
  [ "${#value}" = 64 ] && printf '%s\n' "$value" | grep -Eq '^[0-9a-f]+$' || die 'An owned file hash is invalid.'
  printf '%s\n' "$value"
}
manifest_ok() {
  regular_bounded "$1" 512
  awk 'NR==1 { name="agent" } NR==2 { name="initd" } NR==3 { name="setup.sh" }
    NR>3 || length($1)!=64 || $1 !~ /^[0-9a-f]+$/ || $0 != $1 "  " name { bad=1 }
    END { exit bad || NR!=3 }' "$1" || die 'The payload manifest is not canonical.'
}
manifest_hash() { sed -n "$2"'s/ .*//p' "$1"; }
enrollment_manifest_ok() {
  regular_bounded "$1" 512
  awk 'NR==1 {name="cert.pem"} NR==2 {name="key.pem"} NR==3 {name="ca.pem"} NR==4 {name="vm-id"}
    NR>4 || length($1)!=64 || $1 !~ /^[0-9a-f]+$/ || $0 != $1 "  " name {bad=1}
    END {exit bad || NR!=4}' "$1" || die 'Credential ownership hashes are invalid.'
}
path_present() { [ -e "$1" ] || [ -L "$1" ]; }
assert_absent() { [ ! -e "$1" ] && [ ! -L "$1" ] || die 'Existing state conflicts with a fresh install.'; }
parent_safe() {
  local target parent mode
  target=$1; parent=${target%/*}
  safe_absolute "$target"
  no_symlink_ancestors "$parent"
  while [ ! -e "$parent" ]; do parent=${parent%/*}; [ -n "$parent" ] || parent=/; done
  plain_directory "$parent"
  owner_is "$parent" 0
  mode=$(stat -c %a "$parent")
  [ $((0$mode & 0022)) -eq 0 ] || die 'An installation parent is writable by another user.'
}
ensure_parent() {
  local rest current component
  rest=${1%/*}; no_symlink_ancestors "$rest"; rest=${rest#/}; current=
  while [ -n "$rest" ]; do
    component=${rest%%/*}
    if [ "$rest" = "$component" ]; then rest=; else rest=${rest#*/}; fi
    current=$current/$component
    if [ ! -d "$current" ]; then mkdir -m 755 "$current"; fi
  done
}
program_parents_traversable() {
  local relative directory mode
  for relative in usr usr/local usr/local/libexec; do
    directory=$sysroot/$relative
    if [ -e "$directory" ] || [ -L "$directory" ]; then
      plain_directory "$directory"
      owner_is "$directory" 0
      mode=$(stat -c %a "$directory")
      [ $((0$mode & 0022)) -eq 0 ] || die 'An installation parent is writable by another user.'
      [ $((0$mode & 0001)) -ne 0 ] || die 'The program path is not traversable by its service user.'
    fi
  done
}
copy_bounded() {
  dd if="$1" of="$2" bs=65536 count=$(( $3 / 65536 + 1 )) 2>/dev/null || die 'Bounded staging copy failed; existing state is preserved.'
  regular_bounded "$2" "$3"
}
valid_vm_id() {
  regular_bounded "$1" 37
  [ "$(stat -c %s "$1")" = 37 ] && awk '
    NR==1 && length($0)==36 && $0 ~ /^[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9a-fA-F]+$/ {
      split($0,a,"-"); ok=(length(a[1])==8 && length(a[2])==4 && length(a[3])==4 && length(a[4])==4 && length(a[5])==12)
    } END {exit !(ok && NR==1)}' "$1" || die 'Enrollment requires one canonical UUID line.'
}
normalize_vm_id() {
  printf '%s\n' "$1" | awk '
    NR==1 && length($0)==36 && /^[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9a-fA-F]+$/ {
      split($0,a,"-"); ok=length(a[1])==8 && length(a[2])==4 && length(a[3])==4 && length(a[4])==4 && length(a[5])==12
    } END {exit !(ok && NR==1)}' || die 'Specify one expected VM UUID.'
  printf '%s\n' "$1" | tr A-F a-f
}
row_hash() {
  local row
  regular_bounded "$1" 1048576; owner_is "$1" 0
  row=$(grep '^macopenvm-agent:' "$1") || die 'The reserved account contract changed.'
  [ "${#row}" -le 512 ] && [ "$(printf '%s\n' "$row" | wc -l | tr -d ' ')" = 1 ] || die 'The reserved account contract changed.'
  printf '%s\n' "$row" | sha256sum | awk '{print $1}'
}
account_contract() {
  [ "$(id -u macopenvm-agent)" = "$uid" ] && [ "$(id -g macopenvm-agent)" = "$gid" ] || die 'The reserved account identity changed.'
  awk -F: -v u="$uid" -v g="$gid" '
    $1=="macopenvm-agent" {n++; if(NF!=7 || $2!="x" || $3!=u || $4!=g || $6!="/nonexistent" || $7!="/sbin/nologin") bad=1}
    $3==u && $1!="macopenvm-agent" {bad=1} END {exit bad || n!=1}' "$sysroot/etc/passwd" || die 'The reserved account is not the exact nonlogin identity.'
  awk -F: '$1=="macopenvm-agent" {n++; if(NF!=9 || $2!="!") bad=1} END {exit bad || n!=1}' "$sysroot/etc/shadow" || die 'The reserved account is not locked.'
  awk -F: -v g="$gid" '
    $1=="macopenvm-agent" {n++; if(NF!=4 || $2!="x" || $3!=g || ($4!="" && $4!="macopenvm-agent")) bad=1}
    $3==g && $1!="macopenvm-agent" {bad=1}
    $1!="macopenvm-agent" {split($4,a,","); for(i in a) if(a[i]=="macopenvm-agent") bad=1}
    END {exit bad || n!=1}' "$sysroot/etc/group" || die 'The reserved group contract changed.'
  account_passwd=$(row_hash "$sysroot/etc/passwd")
  account_shadow=$(row_hash "$sysroot/etc/shadow")
  account_group=$(row_hash "$sysroot/etc/group")
  for value in "$account_passwd" "$account_shadow" "$account_group"; do
    [ "${#value}" = 64 ] && printf '%s\n' "$value" | grep -Eq '^[0-9a-f]+$' || die 'The account contract could not be confirmed.'
  done
}
reservation_text() {
  printf 'macopenvm-agent-account-v2\nvm-id=%s\nservice-uid=%s\nservice-gid=%s\npasswd-sha256=%s\nshadow-sha256=%s\ngroup-sha256=%s\ncredentials=%s\ncert-sha256=%s\nkey-sha256=%s\nca-sha256=%s\nvm-id-sha256=%s\n' \
    "$reserved_vm" "$uid" "$gid" "$reserved_passwd" "$reserved_shadow" "$reserved_group" "$reservation_status" \
    "$reserved_cert" "$reserved_key" "$reserved_ca" "$reserved_vm_hash"
}
read_reservation() {
  plain_directory "$reservation"; owner_is "$reservation" 0
  [ "$(stat -c %a "$reservation")" = 700 ] || die 'Account reservation permissions changed.'
  expect_names "$reservation" record
  regular_bounded "$reservation/record" 1024; owner_is "$reservation/record" 0
  [ "$(stat -c %a "$reservation/record")" = 600 ] || die 'Account reservation permissions changed.'
  reserved_vm=$(sed -n '2s/^vm-id=//p' "$reservation/record")
  [ "$(normalize_vm_id "$reserved_vm")" = "$reserved_vm" ] || die 'The account reservation is invalid.'
  uid=$(sed -n '3s/^service-uid=//p' "$reservation/record"); gid=$(sed -n '4s/^service-gid=//p' "$reservation/record")
  case "$uid:$gid" in *[!0-9:]*|:*) die 'The account reservation is invalid.';; esac
  [ "$uid" -gt 0 ] && [ "$gid" -gt 0 ] || die 'The account reservation is invalid.'
  reserved_passwd=$(sed -n '5s/^passwd-sha256=//p' "$reservation/record")
  reserved_shadow=$(sed -n '6s/^shadow-sha256=//p' "$reservation/record")
  reserved_group=$(sed -n '7s/^group-sha256=//p' "$reservation/record")
  reservation_status=$(sed -n '8s/^credentials=//p' "$reservation/record")
  reserved_cert=$(sed -n '9s/^cert-sha256=//p' "$reservation/record")
  reserved_key=$(sed -n '10s/^key-sha256=//p' "$reservation/record")
  reserved_ca=$(sed -n '11s/^ca-sha256=//p' "$reservation/record")
  reserved_vm_hash=$(sed -n '12s/^vm-id-sha256=//p' "$reservation/record")
  case "$reservation_status" in installed|retained|removed) ;; *) die 'The account reservation is invalid.';; esac
  for value in "$reserved_passwd" "$reserved_shadow" "$reserved_group"; do
    [ "${#value}" = 64 ] && printf '%s\n' "$value" | grep -Eq '^[0-9a-f]+$' || die 'The account reservation is invalid.'
  done
  for value in "$reserved_cert" "$reserved_key" "$reserved_ca" "$reserved_vm_hash"; do
    if [ "$reservation_status" = removed ]; then [ "$value" = - ] || die 'The removed reservation is invalid.';
    else [ "${#value}" = 64 ] && printf '%s\n' "$value" | grep -Eq '^[0-9a-f]+$' || die 'The account reservation is invalid.'; fi
  done
  reservation_text | cmp -s - "$reservation/record" || die 'The exact account reservation changed.'
  account_contract
  [ "$account_passwd:$account_shadow:$account_group" = "$reserved_passwd:$reserved_shadow:$reserved_group" ] || die 'The reserved account rows changed.'
}
reservation_credentials() {
  plain_directory "$credentials"; owner_is "$credentials" "$uid"
  [ "$(stat -c %a "$credentials")" = 700 ] || die 'Credential directory permissions changed.'
  expect_names "$credentials" "$(printf 'ca.pem\ncert.pem\nkey.pem\nvm-id')"
  for file in cert.pem key.pem ca.pem vm-id; do
    case "$file" in cert.pem|ca.pem) mode=400 ;; *) mode=600 ;; esac
    regular_bounded "$credentials/$file" 65536; owner_is "$credentials/$file" "$uid"
    [ "$(stat -c %a "$credentials/$file")" = "$mode" ] || die 'Credential permissions changed.'
  done
  valid_vm_id "$credentials/vm-id"
  [ "$(normalize_vm_id "$(cat "$credentials/vm-id")")" = "$reserved_vm" ] || die 'Reserved credentials belong to another VM.'
  [ "$(hash_of "$credentials/cert.pem")" = "$reserved_cert" ] && [ "$(hash_of "$credentials/key.pem")" = "$reserved_key" ] \
    && [ "$(hash_of "$credentials/ca.pem")" = "$reserved_ca" ] && [ "$(hash_of "$credentials/vm-id")" = "$reserved_vm_hash" ] || die 'Reserved credentials changed.'
}
write_reservation() {
  # A leftover next record is a conflict, never authority to resume.
  local record_next
  record_next=$reservation/record.next
  [ "$(stat -c %d "$reservation")" = "$(stat -c %d "${record_next%/*}")" ] || die 'Reservation publication requires one filesystem.'
  assert_absent "$record_next"
  reservation_text >"$record_next"
  chmod 600 "$record_next"; owner_is "$record_next" 0
  sync "$record_next"
  mv "$record_next" "$reservation/record"
  sync "$reservation"
  reservation_text | cmp -s - "$reservation/record" || die 'Reservation publication could not be confirmed.'
}
valid_hash() {
  [ "${#1}" = 64 ] && printf '%s\n' "$1" | grep -Eq '^[0-9a-f]+$' || die 'A generation pin is invalid.'
}
generation_text() {
  printf 'macopenvm-agent-generation-v2\nvm-id=%s\ncurrent=%s\nprevious=%s\nmanager=%s\ninitd=%s\n' \
    "$generation_vm" "$generation_pin" "$generation_previous" "$generation_manager" "$generation_initd"
}
# An exact extra generation entry and v2 marker make the archived v1 manager
# reject before its stop/remove path. There is deliberately no v1 migration.
owned_state_at() {
  local directory file expected
  directory=$1
  plain_directory "$directory"; owner_is "$directory" 0
  [ "$(stat -c %a "$directory")" = 700 ] || die 'The ownership state is not private.'
  expect_names "$directory" "$(printf 'enrollment.sha256\ngeneration\nowner\npayload.sha256')"
  for file in owner payload.sha256 enrollment.sha256 generation; do
    regular_bounded "$directory/$file" 1024; owner_is "$directory/$file" 0
    [ "$(stat -c %a "$directory/$file")" = 600 ] || die 'Ownership record permissions changed.'
  done
  manifest_ok "$directory/payload.sha256"; enrollment_manifest_ok "$directory/enrollment.sha256"
  owned_pin=$(hash_of "$directory/payload.sha256")
  owned_uid=$(sed -n '3s/^service-uid=//p' "$directory/owner"); owned_gid=$(sed -n '4s/^service-gid=//p' "$directory/owner")
  case "$owned_uid:$owned_gid" in *[!0-9:]*|:*) die 'The ownership marker is invalid.';; esac
  [ "$owned_uid" -gt 0 ] && [ "$owned_gid" -gt 0 ] || die 'The ownership marker is invalid.'
  expected=$(printf 'macopenvm-agent-owned-v2\nmanifest-sha256=%s\nservice-uid=%s\nservice-gid=%s\n' "$owned_pin" "$owned_uid" "$owned_gid")
  [ "$(cat "$directory/owner")" = "$expected" ] && [ "$(wc -l <"$directory/owner" | tr -d ' ')" = 4 ] || die 'Legacy or mixed ownership state is unsupported.'
  generation_vm=$(sed -n '2s/^vm-id=//p' "$directory/generation")
  [ "$(normalize_vm_id "$generation_vm")" = "$generation_vm" ] || die 'The generation identity is invalid.'
  generation_pin=$(sed -n '3s/^current=//p' "$directory/generation")
  generation_previous=$(sed -n '4s/^previous=//p' "$directory/generation")
  generation_manager=$(sed -n '5s/^manager=//p' "$directory/generation")
  generation_initd=$(sed -n '6s/^initd=//p' "$directory/generation")
  valid_hash "$generation_pin"; valid_hash "$generation_manager"; valid_hash "$generation_initd"
  [ "$generation_previous" = - ] || valid_hash "$generation_previous"
  [ "$generation_pin" = "$owned_pin" ] && [ "$generation_manager" = "$(manifest_hash "$directory/payload.sha256" 3)" ] \
    && [ "$generation_initd" = "$(manifest_hash "$directory/payload.sha256" 2)" ] || die 'The generation manifest disagrees with owned state.'
  generation_text | cmp -s - "$directory/generation" || die 'The exact generation record changed.'
}
owned_state_contract() { owned_state_at "$state"; }
state_digest() {
  local file value lines result
  lines=
  for file in owner payload.sha256 enrollment.sha256 generation; do
    value=$(hash_of "$1/$file") || die 'Generation state could not be hashed.'
    lines=$lines$value'  '$file'
'
  done
  result=$(printf '%s' "$lines" | sha256sum) || die 'Generation aggregate hashing failed.'
  result=${result%% *}; valid_hash "$result"; printf '%s\n' "$result"
}
program_at() {
  local directory manifest file line
  directory=$1; manifest=$2
  plain_directory "$directory"; owner_is "$directory" 0
  [ "$(stat -c %a "$directory")" = 755 ] || die 'A generation program directory changed.'
  expect_names "$directory" "$(printf 'macopenvm-agent\nsetup.sh')"
  for entry in macopenvm-agent:1 setup.sh:3; do
    file=${entry%:*}; line=${entry#*:}
    case "$file" in setup.sh) regular_bounded "$directory/$file" 131072 ;; *) regular_bounded "$directory/$file" 16777216 ;; esac; owner_is "$directory/$file" 0
    [ "$(stat -c %a "$directory/$file")" = 755 ] && [ "$(hash_of "$directory/$file")" = "$(manifest_hash "$manifest" "$line")" ] || die 'A generation program changed.'
  done
}
compatible_state() {
  [ "$generation_vm" = "$reserved_vm" ] && [ "$owned_uid:$owned_gid" = "$uid:$gid" ] \
    && [ "$generation_manager" = "$manager_hash" ] || die 'Legacy or mixed manager generations are unsupported.'
  [ "$(hash_of "$service")" = "$generation_initd" ] || die 'The service definition changed.'
  (cd "$credentials" && sha256sum -c "$1/enrollment.sha256" >/dev/null 2>&1) || die 'Generation credentials changed.'
}
# Fixed namespace only. A file path from a journal is never executed or removed.
transaction_text() {
  printf 'macopenvm-agent-transaction-v2\noperation=%s\nvm-id=%s\nsource=%s\ntarget=%s\nmanager=%s\nuid=%s\ngid=%s\nreservation=%s\nsource-state=%s\ntarget-state=%s\nphase=%s\n' \
    "$transaction_operation" "$reserved_vm" "$transaction_source" "$transaction_target" "$manager_hash" "$uid" "$gid" \
    "$transaction_reservation" "$transaction_source_state" "$transaction_target_state" "$transaction_phase"
}
write_phase() {
  transaction_phase=$1
  assert_absent "$lock/transaction.next"
  transaction_text >"$lock/transaction.next"
  chmod 600 "$lock/transaction.next"; sync "$lock/transaction.next"
  mv "$lock/transaction.next" "$lock/transaction"
  sync "$lock"
  transaction_text | cmp -s - "$lock/transaction" || die 'Journal publication could not be confirmed.'
}
phase_number() {
  case "$1" in prepared) printf 0 ;; stop) printf 1 ;; save-program) printf 2 ;; save-state) printf 3 ;;
    publish-program) printf 4 ;; publish-state) printf 5 ;; start) printf 6 ;; complete) printf 7 ;;
    *) die 'The transaction phase is invalid.';; esac
}
parse_transaction() {
  local record
  record=$1
  regular_bounded "$record" 2048; owner_is "$record" 0
  [ "$(stat -c %a "$record")" = 600 ] || die 'Journal permissions changed.'
  transaction_operation=$(sed -n '2s/^operation=//p' "$record")
  transaction_source=$(sed -n '4s/^source=//p' "$record")
  transaction_target=$(sed -n '5s/^target=//p' "$record")
  transaction_reservation=$(sed -n '9s/^reservation=//p' "$record")
  transaction_source_state=$(sed -n '10s/^source-state=//p' "$record")
  transaction_target_state=$(sed -n '11s/^target-state=//p' "$record")
  transaction_phase=$(sed -n '12s/^phase=//p' "$record")
  case "$transaction_operation" in upgrade|rollback) ;; *) die 'The transaction operation is invalid.';; esac
  phase_number "$transaction_phase" >/dev/null
  for value in "$transaction_source" "$transaction_target" "$transaction_reservation" "$transaction_source_state" "$transaction_target_state"; do valid_hash "$value"; done
  [ "$transaction_source" != "$transaction_target" ] || die 'Transaction generations must differ.'
  [ "$transaction_reservation" = "$(hash_of "$reservation/record")" ] || die 'The transaction reservation changed.'
  transaction_text | cmp -s - "$record" || die 'The exact transaction journal changed.'
}
transaction_identity() {
  printf '%s:%s:%s:%s:%s:%s' "$transaction_operation" "$transaction_source" "$transaction_target" \
    "$transaction_reservation" "$transaction_source_state" "$transaction_target_state"
}
archive_journal() {
  if [ -e "$2" ] || [ -L "$2" ]; then
    regular_bounded "$2" 2048; owner_is "$2" 0
    [ "$(stat -c %a "$2")" = 600 ] && cmp -s "$1" "$2" || die 'The journal recovery evidence slot is occupied.'
  else cp "$1" "$2"; chmod 600 "$2"; fi
  sync "$2"; sync "$lock"
}
read_transaction() {
  local file old_identity old_phase next_identity next_phase current_file current_identity reverse_identity saved_phase archive_name archive_operation archive_phase archive_kind record_number archive_number
  plain_directory "$lock"; owner_is "$lock" 0
  [ "$(stat -c %a "$lock")" = 700 ] || die 'Transaction evidence permissions changed.'
  for file in "$lock"/* "$lock"/.[!.]* "$lock"/..?*; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    case "${file##*/}" in transaction|transaction.next|previous-transaction) ;;
      recovery-upgrade-*|recovery-rollback-*)
        archive_name=${file##*/}; archive_name=${archive_name#recovery-}; archive_operation=${archive_name%%-*}; archive_name=${archive_name#*-}
        archive_kind=${archive_name##*-}; archive_phase=${archive_name%-*}
        phase_number "$archive_phase" >/dev/null
        [ "$archive_kind" = old ] || [ "$archive_kind" = next ] || die 'A recovery evidence name is invalid.' ;;
      *) die 'The transaction namespace contains unrelated entries.';; esac
  done
  [ -e "$lock/transaction" ] || [ -e "$lock/transaction.next" ] || die 'The transaction journal is absent.'
  current_file=$lock/transaction
  if [ -e "$lock/transaction" ]; then
    parse_transaction "$lock/transaction"; old_identity=$(transaction_identity); old_phase=$(phase_number "$transaction_phase")
  else old_identity=; old_phase=-1; fi
  if [ -e "$lock/transaction.next" ] || [ -L "$lock/transaction.next" ]; then
    [ "$action" = recover ] || die 'An interrupted journal requires explicit recovery.'
    parse_transaction "$lock/transaction.next"; next_identity=$(transaction_identity); next_phase=$(phase_number "$transaction_phase")
    if [ -n "$old_identity" ]; then
      [ "$old_identity" = "$next_identity" ] && [ "$next_phase" -ge "$old_phase" ] && [ "$next_phase" -le $((old_phase+1)) ] \
        || { [ "$transaction_operation" = rollback ] && [ "$transaction_phase" = prepared ] && [ -f "$lock/previous-transaction" ] \
          && cmp -s "$lock/transaction" "$lock/previous-transaction" || die 'Staged journal phases or pins conflict.'; }
    else [ "$transaction_operation" = upgrade ] && [ "$transaction_phase" = prepared ] || die 'The first staged journal is invalid.'; fi
    current_file=$lock/transaction.next
  fi
  parse_transaction "$current_file"
  current_identity=$(transaction_identity); saved_phase=$transaction_phase
  reverse_identity=$(printf 'upgrade:%s:%s:%s:%s:%s' "$transaction_target" "$transaction_source" \
    "$transaction_reservation" "$transaction_target_state" "$transaction_source_state")
  # Every auxiliary record is parsed with exact VM/account/manager pins. It is
  # evidence only; it cannot authorize a phase or introduce a path.
  for file in "$lock/previous-transaction" "$lock"/recovery-*; do
    if [ -e "$file" ] || [ -L "$file" ]; then
      parse_transaction "$file"
      case "${file##*/}" in
        previous-transaction)
          [ "$transaction_operation" = upgrade ] && { [ "$transaction_phase" = start ] || [ "$transaction_phase" = complete ]; } || die 'Prior upgrade evidence is invalid.'
          [ "$(transaction_identity)" = "$current_identity" ] || [ "$(transaction_identity)" = "$reverse_identity" ] || die 'Prior upgrade pins disagree.' ;;
        *) [ "$(transaction_identity)" = "$current_identity" ] || [ "$(transaction_identity)" = "$reverse_identity" ] || die 'Recovery evidence pins disagree.'
          archive_name=${file##*/}; archive_name=${archive_name#recovery-}; archive_operation=${archive_name%%-*}; archive_name=${archive_name#*-}
          archive_kind=${archive_name##*-}; archive_phase=${archive_name%-*}
          record_number=$(phase_number "$transaction_phase"); archive_number=$(phase_number "$archive_phase")
          if [ "$archive_operation" = "$transaction_operation" ]; then
            if [ "$archive_kind" = next ]; then [ "$record_number" = "$archive_number" ] || die 'Recovery phase evidence disagrees.';
            else [ "$record_number" -le "$archive_number" ] && [ "$record_number" -ge $((archive_number-1)) ] || die 'Recovery phase evidence disagrees.'; fi
          else [ "$archive_operation:$archive_phase:$archive_kind:$transaction_operation" = rollback:prepared:old:upgrade ] \
            && { [ "$transaction_phase" = start ] || [ "$transaction_phase" = complete ]; } || die 'Recovery operation evidence disagrees.'; fi ;;
      esac
    fi
  done
  parse_transaction "$current_file"
  if [ "$transaction_operation" = upgrade ] && [ -e "$lock/previous-transaction" ]; then
    # Crash after archiving the old journal but before the rollback journal:
    # only explicit reversed caller pins can authorize this exact transition.
    [ "$action" = recover ] && [ "$transaction_source:$transaction_target" = "$target_generation:$expected_generation" ] \
      && { [ "$transaction_phase" = start ] || [ "$transaction_phase" = complete ]; } || die 'Archived rollback transition requires its exact recovery pins.'
    validate_layout
    old_source_state=$transaction_source_state
    transaction_source=$expected_generation; transaction_target=$target_generation
    transaction_source_state=$transaction_target_state; transaction_target_state=$old_source_state
    transaction_operation=rollback; transaction_phase=prepared
    validate_layout; write_phase prepared
  elif [ "$current_file" = "$lock/transaction.next" ]; then
    [ "$transaction_source:$transaction_target" = "$expected_generation:$target_generation" ] || die 'Recovery pins disagree with the staged journal.'
    # Inspect the exact phase-specific A/B layout before preserving both records
    # and publishing the fully written next journal. Partial records refuse.
    validate_layout
    # Fixed operation/phase slots admit repeated later interruptions while
    # preserving earlier bytes. At most 32 bounded records can exist per cycle.
    archive_name=recovery-$transaction_operation-$transaction_phase
    if [ -e "$lock/transaction" ]; then archive_journal "$lock/transaction" "$lock/$archive_name-old"; fi
    archive_journal "$lock/transaction.next" "$lock/$archive_name-next"
    mv "$lock/transaction.next" "$lock/transaction"; sync "$lock"
    parse_transaction "$lock/transaction"
  fi
}

rename_generation() {
  # Both names are direct siblings; verify the filesystem rather than accepting mv's copy fallback.
  [ "$(stat -c %d "$1")" = "$(stat -c %d "${2%/*}")" ] \
    && [ "$(stat -c %d "${1%/*}")" = "$(stat -c %d "${2%/*}")" ] || die 'Generation renames must stay on one filesystem.'
  assert_absent "$2"
  mv "$1" "$2"
  sync "${1%/*}"; sync "${2%/*}"
}
# OpenRC acknowledgement alone is insufficient. The mounted kernel view must
# show neither a dedicated-UID child nor this service's root supervisor/pending
# child. PID files, journal phases and logs are never process authority.
process_read() {
  # Limits apply to raw bytes; a read error is never an empty argument vector.
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  dd if="$1" of="$process_scratch/$2" bs=1 count="$3" 2>/dev/null || return 1
  [ "$(stat -c %s "$process_scratch/$2")" -lt "$3" ] || return 1
}
process_refuse() {
  rm -f "$process_scratch/status" "$process_scratch/cmdline" "$process_scratch/arguments" "$process_scratch/filtered"
  rmdir "$process_scratch"
  die "$1"
}
process_identity() {
  [ ! -L "$process" ] || process_refuse 'A kernel process directory is indirect.'
  if ! process_read "$process/status" status 65537; then
    [ ! -d "$process" ] && return 2
    process_refuse 'A process status could not be read completely.'
  fi
  process_shape=$(awk -v pid="${process##*/}" '
    /^Uid:/ {u++; if(NF!=5) bad=1; for(i=2;i<=5;i++) {if($i !~ /^[0-9]+$/) bad=1; ids=ids $i " "}}
    /^Pid:/ {p++; if(NF!=2 || $2!=pid) bad=1}
    /^Tgid:/ {t++; if(NF!=2 || $2!=pid) bad=1}
    /^State:/ {s++; if(NF<2 || $2 !~ /^[RSDTtXZPI]$/) bad=1; state=$2}
    /^Kthread:/ {k++; if(NF!=2 || ($2!="0" && $2!="1")) bad=1; kernel=$2}
    END {if(bad || u!=1 || p!=1 || t!=1 || s!=1 || k>1) exit 1; print state ":" kernel ":" ids}' "$process_scratch/status") \
    || { [ ! -d "$process" ] && return 2; process_refuse 'A kernel process identity is malformed.'; }
  process_state=${process_shape%%:*}; process_shape=${process_shape#*:}
  kernel_thread=${process_shape%%:*}; ids=${process_shape#*:}
  for value in $ids; do [ "$value" != "$uid" ] || process_refuse 'A service process is still present.'; done
  return 0
}
process_without_executable() {
  case "$process_state" in Z|X) ;; *)
    [ "$kernel_thread" = 1 ] && [ "$ids" = '0 0 0 0 ' ] || return 1;; esac
  process_read "$process/cmdline" cmdline 4097 || { [ ! -d "$process" ] && return 2; process_refuse 'A process cannot be read completely.'; }
  [ "$(stat -c %s "$process_scratch/cmdline")" = 0 ] || process_refuse 'A non-user process has unexpected arguments.'
  return 0
}
service_quiescent() {
  local result proc_root ids process count exe_identity supervisor_identity agent_identities directory identity process_shape process_state kernel_thread
  if rc-service macopenvm-agent status >/dev/null 2>&1 9>&-; then result=0; else result=$?; fi
  [ "$result" = 3 ] || die 'The service is not demonstrably stopped.'
  proc_root=/proc; [ "$test_mode" = no ] || proc_root=$sysroot/proc
  plain_directory "$proc_root"
  [ "$(stat -f -c %T "$proc_root")" = proc ] || die 'A mounted process filesystem is required.'
  supervisor_identity=$(stat -L -c '%d:%i' "$(command -v supervise-daemon)") || die 'Supervisor identity cannot be confirmed.'
  agent_identities=
  for directory in "$program" "$program_next" "$program_previous" "$program_failed" "$program_retired"/*/program; do
    if [ -f "$directory/macopenvm-agent" ]; then
      identity=$(stat -c '%d:%i' "$directory/macopenvm-agent") || die 'Agent process identity cannot be confirmed.'
      agent_identities=$agent_identities' '$identity
    fi
  done
  process_scratch=$(mktemp -d "$sysroot/var/lib/.macopenvm-agent-proc.XXXXXX") || die 'Private process inspection could not be prepared.'
  count=0
  for process in "$proc_root"/[0-9]*; do
    [ ! -L "$process" ] || process_refuse 'A kernel process directory is indirect.'
    [ -d "$process" ] || continue
    count=$((count+1)); [ "$count" -le 4096 ] || process_refuse 'The process inspection bound was exceeded.'
    if ! process_identity; then continue; fi
    if process_without_executable; then continue; else [ "$?" = 2 ] && continue; fi
    if [ ! -L "$process/exe" ] || ! exe_identity=$(stat -L -c '%d:%i' "$process/exe"); then
      # A live snapshot can race exit. Only a fresh valid identity and empty
      # terminal/kernel cmdline qualify; permission/read failure never does.
      if process_identity; then
        if process_without_executable; then continue; else [ "$?" = 2 ] && continue; fi
      else continue; fi
      process_refuse 'A process executable cannot be inspected.'
    fi
    for identity in $agent_identities; do [ "$exe_identity" != "$identity" ] || process_refuse 'An agent process is still present.'; done
    if [ "$exe_identity" = "$supervisor_identity" ]; then
      process_read "$process/cmdline" cmdline 4097 || process_refuse 'Supervisor arguments could not be read completely.'
      [ "$(stat -c %s "$process_scratch/cmdline")" -gt 0 ] \
        && [ "$(tail -c 1 "$process_scratch/cmdline" | od -An -tu1 | tr -d ' ')" = 0 ] || process_refuse 'Supervisor arguments are malformed.'
      # NUL boundaries remain authoritative; control bytes in arguments fail closed.
      LC_ALL=C tr -d '\000\040-\176' <"$process_scratch/cmdline" >"$process_scratch/filtered" || process_refuse 'Supervisor arguments cannot be filtered.'
      [ "$(stat -c %s "$process_scratch/filtered")" = 0 ] || process_refuse 'Supervisor arguments are malformed.'
      rm "$process_scratch/filtered"
      tr '\000' '\n' <"$process_scratch/cmdline" >"$process_scratch/arguments" || process_refuse 'Supervisor arguments cannot be decoded.'
      awk 'NR==1 {if($0!="supervise-daemon" && $0 !~ /\/supervise-daemon$/) bad=1}
        NR==2 {if($0 !~ /^[A-Za-z0-9._-]+$/) bad=1} END {exit bad || NR<2}' "$process_scratch/arguments" \
        || { rm "$process_scratch/arguments"; process_refuse 'Supervisor argument identity is malformed.'; }
      if grep -Fx macopenvm-agent "$process_scratch/arguments" >/dev/null; then
        rm "$process_scratch/arguments"; process_refuse 'The service supervisor is still present.'
      fi
      rm "$process_scratch/arguments"
    fi
  done
  rm -f "$process_scratch/status" "$process_scratch/cmdline" "$process_scratch/arguments" "$process_scratch/filtered"; rmdir "$process_scratch"
  if rc-service macopenvm-agent status >/dev/null 2>&1 9>&-; then result=0; else result=$?; fi
  [ "$result" = 3 ] || die 'The service changed during quiescence inspection.'
}
normal_stop() {
  rc-service macopenvm-agent stop >/dev/null 2>&1 9>&- || die 'Normal service stop failed; all generation evidence is preserved.'
  service_quiescent
}

# Retirement archives evidence only. It never copies credentials, deletes a
# generation, migrates a manager, or treats a saved service ACK as quiescence.
retirement_directory() {
  plain_directory "$1"; owner_is "$1" 0
  [ "$(stat -c %a "$1")" = 700 ] || die 'Retirement evidence is not private.'
}
retirement_inode() {
  local value
  value=$(stat -c '%d:%i' "$1") || die 'Retirement inode identity cannot be read.'
  printf '%s\n' "$value" | grep -Eq '^[0-9]+:[0-9]+$' || die 'Retirement inode identity is invalid.'
  printf '%s\n' "$value"
}
retirement_phase_number() {
  case "$1" in prepared) printf 0 ;; stop) printf 1 ;; archives) printf 2 ;; program) printf 3 ;;
    state) printf 4 ;; journals) printf 5 ;; complete) printf 6 ;; *) die 'Retirement phase is invalid.';; esac
}
retirement_text() {
  printf 'macopenvm-agent-retirement-v1\nvm-id=%s\nretirement-id=%s\ncurrent=%s\nfailed=%s\nmanager=%s\ninitd=%s\nuid=%s\ngid=%s\nreservation=%s\ncurrent-state=%s\nfailed-state=%s\ncohort=%s\ncurrent-program-inode=%s\ncurrent-state-inode=%s\nfailed-program-inode=%s\nfailed-state-inode=%s\ncohort-inode=%s\nphase=%s\n' \
    "$rt_vm" "$rt_id" "$rt_current" "$rt_failed" "$rt_manager" "$rt_initd" "$rt_uid" "$rt_gid" "$rt_reservation" \
    "$rt_current_state" "$rt_failed_state" "$rt_cohort" "$rt_current_program_inode" "$rt_current_state_inode" \
    "$rt_failed_program_inode" "$rt_failed_state_inode" "$rt_cohort_inode" "$rt_phase"
}
retirement_identity() {
  local saved value
  saved=$rt_phase; rt_phase=prepared
  value=$(retirement_text | sha256sum) || die 'Retirement identity cannot be hashed.'
  rt_phase=$saved; value=${value%% *}; valid_hash "$value"; printf '%s\n' "$value"
}
parse_retirement() {
  local record value
  record=$1; regular_bounded "$record" 2048; owner_is "$record" 0
  [ "$(stat -c %a "$record")" = 600 ] || die 'Retirement journal permissions changed.'
  rt_vm=$(sed -n '2s/^vm-id=//p' "$record"); rt_id=$(sed -n '3s/^retirement-id=//p' "$record")
  [ "$(normalize_vm_id "$rt_vm")" = "$rt_vm" ] && [ "$(normalize_vm_id "$rt_id")" = "$rt_id" ] || die 'Retirement UUIDs are invalid.'
  rt_current=$(sed -n '4s/^current=//p' "$record"); rt_failed=$(sed -n '5s/^failed=//p' "$record")
  rt_manager=$(sed -n '6s/^manager=//p' "$record"); rt_initd=$(sed -n '7s/^initd=//p' "$record")
  rt_uid=$(sed -n '8s/^uid=//p' "$record"); rt_gid=$(sed -n '9s/^gid=//p' "$record")
  rt_reservation=$(sed -n '10s/^reservation=//p' "$record")
  rt_current_state=$(sed -n '11s/^current-state=//p' "$record"); rt_failed_state=$(sed -n '12s/^failed-state=//p' "$record")
  rt_cohort=$(sed -n '13s/^cohort=//p' "$record")
  rt_current_program_inode=$(sed -n '14s/^current-program-inode=//p' "$record")
  rt_current_state_inode=$(sed -n '15s/^current-state-inode=//p' "$record")
  rt_failed_program_inode=$(sed -n '16s/^failed-program-inode=//p' "$record")
  rt_failed_state_inode=$(sed -n '17s/^failed-state-inode=//p' "$record")
  rt_cohort_inode=$(sed -n '18s/^cohort-inode=//p' "$record"); rt_phase=$(sed -n '19s/^phase=//p' "$record")
  for value in "$rt_current" "$rt_failed" "$rt_manager" "$rt_initd" "$rt_reservation" "$rt_current_state" "$rt_failed_state" "$rt_cohort"; do valid_hash "$value"; done
  [ "$rt_current" != "$rt_failed" ] || die 'Retirement generations must differ.'
  printf '%s\n' "$rt_uid:$rt_gid" | grep -Eq '^[1-9][0-9]*:[1-9][0-9]*$' || die 'Retirement account identity is invalid.'
  for value in "$rt_current_program_inode" "$rt_current_state_inode" "$rt_failed_program_inode" "$rt_failed_state_inode" "$rt_cohort_inode"; do
    printf '%s\n' "$value" | grep -Eq '^[0-9]+:[0-9]+$' || die 'Retirement inode identity is invalid.'
  done
  retirement_phase_number "$rt_phase" >/dev/null
  retirement_text | cmp -s - "$record" || die 'The exact retirement journal changed.'
}
retirement_context() {
  [ "$rt_vm:$rt_uid:$rt_gid:$rt_manager" = "$reserved_vm:$uid:$gid:$manager_hash" ] || die 'Retirement belongs to another VM, account or manager.'
}
retirement_caller() {
  retirement_context
  [ "$rt_vm:$rt_id:$rt_current:$rt_failed" = "$expected_vm:$retirement_id:$expected_generation:$target_generation" ] || die 'Retirement caller pins disagree with the journal.'
  [ "$reservation_status" = installed ] && [ "$rt_reservation" = "$(hash_of "$reservation/record")" ] || die 'Retirement reservation changed.'
  [ "$rt_initd" = "$(hash_of "$service")" ] || die 'Retirement service definition changed.'
}
# Historical cohorts are checked against their retirement receipt, not today's
# mutable reservation status. A later explicit uninstall may retain/remove keys.
retirement_cohort() {
  local directory file name operation phase source target source_state target_state identity_value lines count kind named_phase record_number named_number
  directory=$1; retirement_directory "$directory"
  [ "$(retirement_inode "$directory")" = "$rt_cohort_inode" ] || die 'Retirement cohort inode changed.'
  lines=; count=0
  for file in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
    path_present "$file" || continue
    name=${file##*/}; count=$((count+1)); [ "$count" -le 34 ] || die 'Retirement cohort is too large.'
    regular_bounded "$file" 2048; owner_is "$file" 0
    [ "$(stat -c %a "$file")" = 600 ] || die 'Archived generation journal permissions changed.'
    operation=$(sed -n '2s/^operation=//p' "$file"); phase=$(sed -n '12s/^phase=//p' "$file")
    record_number=$(phase_number "$phase")
    case "$operation" in
      upgrade) source=$rt_current; target=$rt_failed; source_state=$rt_current_state; target_state=$rt_failed_state ;;
      rollback) source=$rt_failed; target=$rt_current; source_state=$rt_failed_state; target_state=$rt_current_state ;;
      *) die 'Archived generation operation is invalid.';; esac
    case "$name" in
      transaction) [ "$operation:$phase" = rollback:complete ] || die 'Retirement requires a completed rollback.' ;;
      previous-transaction) [ "$operation" = upgrade ] && { [ "$phase" = start ] || [ "$phase" = complete ]; } || die 'Retirement upgrade cohort is invalid.' ;;
      recovery-upgrade-*|recovery-rollback-*)
        named_phase=${name#recovery-}; identity_value=${named_phase%%-*}; named_phase=${named_phase#*-}
        kind=${named_phase##*-}; named_phase=${named_phase%-*}; named_number=$(phase_number "$named_phase")
        if [ "$identity_value" = "$operation" ]; then
          case "$kind" in next) [ "$record_number" = "$named_number" ] || die 'Retirement recovery phase disagrees.' ;;
            old) [ "$record_number" -le "$named_number" ] && [ "$record_number" -ge $((named_number-1)) ] || die 'Retirement recovery phase disagrees.' ;;
            *) die 'Retirement recovery name is invalid.';; esac
        else [ "$identity_value:$named_phase:$kind:$operation" = rollback:prepared:old:upgrade ] \
          && { [ "$phase" = start ] || [ "$phase" = complete ]; } || die 'Retirement recovery operation disagrees.'; fi ;;
      *) die 'Retirement cohort contains unrelated entries.';; esac
    printf 'macopenvm-agent-transaction-v2\noperation=%s\nvm-id=%s\nsource=%s\ntarget=%s\nmanager=%s\nuid=%s\ngid=%s\nreservation=%s\nsource-state=%s\ntarget-state=%s\nphase=%s\n' \
      "$operation" "$rt_vm" "$source" "$target" "$rt_manager" "$rt_uid" "$rt_gid" "$rt_reservation" "$source_state" "$target_state" "$phase" \
      | cmp -s - "$file" || die 'The exact archived generation cohort changed.'
    identity_value=$(hash_of "$file") || die 'Retirement cohort could not be hashed.'
    lines=$lines$identity_value'  '$name'
'
  done
  [ -f "$directory/transaction" ] && [ -f "$directory/previous-transaction" ] || die 'Retirement cohort is incomplete.'
  identity_value=$(printf '%s' "$lines" | sha256sum) || die 'Retirement cohort aggregate failed.'
  identity_value=${identity_value%% *}; valid_hash "$identity_value"
  if [ -n "$rt_cohort" ]; then [ "$identity_value" = "$rt_cohort" ] || die 'Retirement cohort bytes changed.'; else rt_cohort=$identity_value; fi
}
retirement_failed() {
  owned_state_at "$1"
  [ "$owned_pin:$generation_previous:$generation_vm:$owned_uid:$owned_gid:$generation_manager:$generation_initd" = \
    "$rt_failed:$rt_current:$rt_vm:$rt_uid:$rt_gid:$rt_manager:$rt_initd" ] \
    && [ "$(state_digest "$1")" = "$rt_failed_state" ] && [ "$(retirement_inode "$1")" = "$rt_failed_state_inode" ] || die 'Retired failed state changed.'
  program_at "$2" "$1/payload.sha256"
  [ "$(retirement_inode "$2")" = "$rt_failed_program_inode" ] || die 'Retired failed program inode changed.'
}
retirement_record_namespace() {
  local directory file name identity_value saved_identity saved_phase kind named_phase number named_number
  directory=$1; retirement_directory "$directory"
  saved_identity=$(retirement_identity); saved_phase=$rt_phase
  for file in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
    path_present "$file" || continue
    name=${file##*/}
    case "$name" in record|record.next|confirmation|confirmation.next|confirmation-unconfirmed) continue ;;
      recovery-*-old|recovery-*-next) named_phase=${name#recovery-}; kind=${named_phase##*-}; named_phase=${named_phase%-*}; named_number=$(retirement_phase_number "$named_phase") ;;
      *) die 'Retirement journal contains unrelated entries.';; esac
    parse_retirement "$file"; identity_value=$(retirement_identity)
    [ "$identity_value" = "$saved_identity" ] || die 'Retirement recovery pins disagree.'
    number=$(retirement_phase_number "$rt_phase")
    if [ "$kind" = next ]; then [ "$number" = "$named_number" ] || die 'Retirement recovery phase disagrees.';
    else [ "$number" -ge $((named_number-1)) ] && [ "$number" -le "$named_number" ] || die 'Retirement recovery phase disagrees.'; fi
  done
  rt_phase=$saved_phase
}
retirement_complete_archive() {
  local directory id
  id=$1; directory=$state_retired/$id
  retirement_directory "$program_retired/$id"; expect_names "$program_retired/$id" program
  retirement_directory "$directory"; expect_names "$directory" "$(printf 'journals\nretirement\nstate')"
  retirement_directory "$directory/retirement"; assert_absent "$directory/retirement/record.next"
  assert_absent "$directory/retirement/confirmation.next"
  assert_absent "$directory/retirement/confirmation-unconfirmed"
  parse_retirement "$directory/retirement/record"; retirement_context
  [ "$rt_id:$rt_phase" = "$id:complete" ] || die 'Retirement archive receipt is incomplete.'
  retirement_record_namespace "$directory/retirement"
  regular_bounded "$directory/retirement/confirmation" 2048; owner_is "$directory/retirement/confirmation" 0
  [ "$(stat -c %a "$directory/retirement/confirmation")" = 600 ] && cmp -s "$directory/retirement/record" "$directory/retirement/confirmation" \
    || die 'Retirement completion has not been confirmed.'
  retirement_failed "$directory/state" "$program_retired/$id/program"
  retirement_cohort "$directory/journals"
}
retirement_inventory() {
  local directory entry id ids seen count selected
  ids=; count=0; selected=no
  for directory in "$program_retired" "$state_retired"; do
    if path_present "$directory"; then
      retirement_directory "$directory"
      for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
        path_present "$entry" || continue
        id=${entry##*/}; [ "$(normalize_vm_id "$id")" = "$id" ] || die 'Retirement archive name is invalid.'
        case " $ids " in *" $id "*) ;; *) ids=$ids' '$id; count=$((count+1));; esac
        [ "$count" -le 8 ] || die 'Retirement archive capacity is exceeded.'
      done
    fi
  done
  for id in $ids; do
    if [ "$action" = retire-failed ] && [ "$id" = "$retirement_id" ] && [ "$resume" = yes ]; then
      selected=yes
      for directory in "$program_retired/$id" "$state_retired/$id"; do
        if path_present "$directory"; then retirement_directory "$directory"; fi
      done
    else retirement_complete_archive "$id"; fi
  done
  retirement_count=$count
  if path_present "$retirement_stage"; then
    assert_absent "$retirement"
    [ "$action" = retire-failed ] && [ "$resume" = yes ] || die 'Staged retirement requires its explicit resume operation.'
    retirement_directory "$retirement_stage"
  fi
  if path_present "$retirement"; then
    [ "$action" = retire-failed ] && [ "$resume" = yes ] || die 'Unfinished retirement requires its explicit resume operation.'
  elif [ "$action" = retire-failed ] && ! path_present "$retirement_stage"; then
    case " $ids " in *" $retirement_id "*) [ "$resume" = yes ] || die 'The selected retirement archive is already occupied.' ;; *) [ "$resume" = no ] || die 'No retirement journal or completed receipt matches resume.';; esac
  fi
}
retirement_layout() {
  local source_program source_state source_cohort first last step present candidate names
  for candidate in "$program_next" "$program_previous" "$state_next" "$state_previous"; do assert_absent "$candidate"; done
  source_program=$program_failed; source_state=$state_failed; source_cohort=$lock; step=0
  if path_present "$program_archive/program"; then assert_absent "$program_failed"; source_program=$program_archive/program; step=1; else path_present "$program_failed" || die 'Retirement failed program is absent.'; fi
  if path_present "$state_archive/state"; then
    [ "$step" = 1 ] || die 'Retirement state move is out of order.'
    assert_absent "$state_failed"; source_state=$state_archive/state; step=2
  else path_present "$state_failed" || die 'Retirement failed state is absent.'; fi
  if path_present "$state_archive/journals"; then
    [ "$step" = 2 ] || die 'Retirement cohort move is out of order.'
    assert_absent "$lock"; source_cohort=$state_archive/journals; step=3
  else path_present "$lock" || die 'Retirement cohort is absent.'; fi
  case "$rt_phase" in prepared|stop|archives) first=0; last=0 ;; program) first=0; last=1 ;;
    state) first=1; last=2 ;; journals) first=2; last=3 ;; complete) first=3; last=3 ;; esac
  [ "$step" -ge "$first" ] && [ "$step" -le "$last" ] || die 'Retirement namespace does not match its phase.'
  for candidate in "$program_archive" "$state_archive"; do
    if path_present "$candidate"; then
      retirement_directory "$candidate"
      case "$rt_phase" in prepared|stop) die 'Retirement archive appeared before its recorded phase.';; esac
    else case "$rt_phase" in prepared|stop|archives) ;; *) die 'Retirement archive container is absent.';; esac; fi
  done
  if [ -d "$program_archive" ]; then names=; [ "$step" -lt 1 ] || names=program; expect_names "$program_archive" "$names"; fi
  if [ -d "$state_archive" ]; then
    names=; [ "$step" -lt 2 ] || names=state
    [ "$step" -lt 3 ] || names=$(printf 'journals\nstate')
    if path_present "$state_archive/retirement"; then
      [ "$rt_phase" = complete ] && ! path_present "$retirement" || die 'Retirement receipt appeared before completion.'
      names=$(printf 'journals\nretirement\nstate')
    fi
    expect_names "$state_archive" "$names"
  fi
  owned_state_contract; compatible_state "$state"; program_at "$program" "$state/payload.sha256"
  [ "$owned_pin:$generation_previous" = "$rt_current:-" ] && [ "$(state_digest "$state")" = "$rt_current_state" ] \
    && [ "$(retirement_inode "$program")" = "$rt_current_program_inode" ] && [ "$(retirement_inode "$state")" = "$rt_current_state_inode" ] || die 'Retirement current generation changed.'
  retirement_failed "$source_state" "$source_program"
  compatible_state "$source_state"
  retirement_cohort "$source_cohort"
  retirement_step=$step
}
retirement_publish_record() {
  regular_bounded "$1" 2048; owner_is "$1" 0
  [ "$(stat -c %a "$1")" = 600 ] && [ "$(stat -c %d "$1")" = "$(stat -c %d "${2%/*}")" ] \
    && [ "$(stat -c %d "${1%/*}")" = "$(stat -c %d "${2%/*}")" ] || die 'Retirement journal rename must remain on one filesystem.'
  retirement_text | cmp -s - "$1" || die 'Staged retirement journal changed before publication.'
  mv "$1" "$2"; sync "${2%/*}"
}
write_retirement_phase() {
  rt_phase=$1; assert_absent "$retirement/record.next"
  retirement_text >"$retirement/record.next"; chmod 600 "$retirement/record.next"
  sync "$retirement/record.next"
  retirement_publish_record "$retirement/record.next" "$retirement/record"
  retirement_text | cmp -s - "$retirement/record" || die 'Retirement journal publication cannot be confirmed.'
}
retirement_preserve_record() {
  if path_present "$2"; then
    regular_bounded "$2" 2048; owner_is "$2" 0
    [ "$(stat -c %a "$2")" = 600 ] && cmp -s "$1" "$2" || die 'Retirement recovery evidence slot is occupied.'
  else cp "$1" "$2"; chmod 600 "$2"; fi
  sync "$2"; sync "$retirement"
}
read_retirement() {
  local old_identity old_phase next_identity next_phase file phase
  retirement_directory "$retirement"
  assert_absent "$retirement/confirmation"; assert_absent "$retirement/confirmation.next"; assert_absent "$retirement/confirmation-unconfirmed"
  file=$retirement/record; old_identity=; old_phase=-1
  if path_present "$file"; then parse_retirement "$file"; old_identity=$(retirement_identity); old_phase=$(retirement_phase_number "$rt_phase"); fi
  if path_present "$retirement/record.next"; then
    file=$retirement/record.next; parse_retirement "$file"
    next_identity=$(retirement_identity); next_phase=$(retirement_phase_number "$rt_phase")
    if [ -n "$old_identity" ]; then
      [ "$old_identity" = "$next_identity" ] && [ "$next_phase" -ge "$old_phase" ] && [ "$next_phase" -le $((old_phase+1)) ] || die 'Retirement staged phase or pins conflict.'
    else [ "$rt_phase" = prepared ] || die 'The initial retirement journal is invalid.'; fi
  else [ -n "$old_identity" ] || die 'Retirement journal is absent.'; fi
  retirement_caller; retirement_record_namespace "$retirement"
  parse_retirement "$file"; retirement_layout
  if [ "$file" = "$retirement/record.next" ]; then
    phase=$rt_phase
    if path_present "$retirement/record"; then retirement_preserve_record "$retirement/record" "$retirement/recovery-$phase-old"; fi
    retirement_preserve_record "$retirement/record.next" "$retirement/recovery-$phase-next"
    retirement_publish_record "$retirement/record.next" "$retirement/record"
    parse_retirement "$retirement/record"
  fi
}
retirement_make_directory() {
  if path_present "$1"; then retirement_directory "$1"; else
    parent_safe "$1"; mkdir -m 700 "$1"; sync "$1"; sync "${1%/*}"
  fi
}
retirement_confirmation_file() {
  regular_bounded "$1" 2048; owner_is "$1" 0
  [ "$(stat -c %a "$1")" = 600 ] && cmp -s "$state_archive/retirement/record" "$1" \
    || die 'Retirement completion evidence changed.'
}
confirm_retirement() {
  local receipt
  receipt=$state_archive/retirement
  retirement_directory "$receipt"; assert_absent "$receipt/record.next"
  parse_retirement "$receipt/record"; retirement_caller
  [ "$rt_phase" = complete ] || die 'Archived retirement is not at its final boundary.'
  retirement_record_namespace "$receipt"; retirement_layout
  if path_present "$receipt/confirmation"; then
    assert_absent "$receipt/confirmation.next"; retirement_confirmation_file "$receipt/confirmation"
    if ! path_present "$receipt/confirmation-unconfirmed"; then return; fi
  fi
  # A persistent exact marker precedes confirmation publication. Observed
  # publication/flush failure blocks other mutators until explicit reflush.
  # It cannot prove an unobservable SIGKILL/power-loss final window.
  if path_present "$receipt/confirmation-unconfirmed"; then
    retirement_confirmation_file "$receipt/confirmation-unconfirmed"
  fi
  if path_present "$receipt/confirmation.next"; then retirement_confirmation_file "$receipt/confirmation.next"; fi
  normal_stop; retirement_layout
  sync "$state_archive"; sync "${retirement%/*}"; sync "$receipt"
  if ! path_present "$receipt/confirmation-unconfirmed"; then
    retirement_text >"$receipt/confirmation-unconfirmed"; chmod 600 "$receipt/confirmation-unconfirmed"
  fi
  retirement_confirmation_file "$receipt/confirmation-unconfirmed"
  sync "$receipt/confirmation-unconfirmed"; sync "$receipt"
  if ! path_present "$receipt/confirmation"; then
    if ! path_present "$receipt/confirmation.next"; then
      retirement_text >"$receipt/confirmation.next"; chmod 600 "$receipt/confirmation.next"
    fi
    retirement_confirmation_file "$receipt/confirmation.next"; sync "$receipt/confirmation.next"
    retirement_publish_record "$receipt/confirmation.next" "$receipt/confirmation"
  else sync "$receipt/confirmation"; sync "$receipt"; fi
  # Only this exact control marker is removed after positive confirmation
  # flush. Cleanup failure leaves either a resumable marker, or an already
  # confirmed durable record; it never deletes generation/recovery evidence.
  rm "$receipt/confirmation-unconfirmed"; sync "$receipt"
}
publish_prepared_retirement() {
  retirement_directory "$retirement_stage"; expect_names "$retirement_stage" record
  parse_retirement "$retirement_stage/record"; retirement_caller
  [ "$rt_phase" = prepared ] || die 'Staged retirement must be at its prepared boundary.'
  assert_absent "$retirement"; retirement_layout
  sync "$retirement_stage/record"; sync "$retirement_stage"
  rename_generation "$retirement_stage" "$retirement"
}
resume_retirement() {
  retirement_caller; retirement_layout
  # Each invocation repeats the real stop/proc proof. No journal phase or PID
  # authorizes a later side effect, and this operation never starts the service.
  if [ "$rt_phase" = prepared ]; then write_retirement_phase stop; fi
  normal_stop; retirement_layout
  case "$rt_phase" in stop|archives)
    [ "$rt_phase" = archives ] || write_retirement_phase archives
    for directory in "$program_retired" "$state_retired" "$program_archive" "$state_archive"; do
      service_quiescent; retirement_make_directory "$directory"
    done ;;
  esac
  while [ "$retirement_step" -lt 3 ]; do
    service_quiescent
    case "$retirement_step" in
      0) [ "$rt_phase" = program ] || write_retirement_phase program; retirement_layout; rename_generation "$program_failed" "$program_archive/program" ;;
      1) [ "$rt_phase" = state ] || write_retirement_phase state; retirement_layout; rename_generation "$state_failed" "$state_archive/state" ;;
      2) [ "$rt_phase" = journals ] || write_retirement_phase journals; retirement_layout; rename_generation "$lock" "$state_archive/journals" ;;
    esac
    retirement_step=$((retirement_step+1))
  done
  [ "$rt_phase" = complete ] || write_retirement_phase complete
  retirement_layout; service_quiescent
  rename_generation "$retirement" "$state_archive/retirement"
  confirm_retirement
  retirement_complete_archive "$retirement_id"
  printf '%s\n' 'Experimental failed generation retired. Exact evidence is retained; service restart remains explicit.'
}

if [ -n "$sysroot" ] || [ -n "$command_dir" ] || [ "${MACOPENVM_AGENT_TEST_MODE:-}" = 1 ]; then
  [ "${MACOPENVM_AGENT_TEST_MODE:-}" = 1 ] && [ -n "$sysroot" ] && [ -n "$command_dir" ] || die 'Test injection requires both private test paths and its explicit mode.'
  plain_directory "$sysroot"; plain_directory "$command_dir"
  [ -f "$sysroot/.macopenvm-agent-test-root" ] && [ ! -L "$sysroot/.macopenvm-agent-test-root" ] && [ "$(cat "$sysroot/.macopenvm-agent-test-root")" = macopenvm-agent-test-root-v1 ] || die 'The test root sentinel is missing.'
  [ -f "$command_dir/.macopenvm-agent-test-commands" ] && [ ! -L "$command_dir/.macopenvm-agent-test-commands" ] && [ "$(cat "$command_dir/.macopenvm-agent-test-commands")" = macopenvm-agent-test-commands-v1 ] || die 'The test command sentinel is missing.'
  test_mode=yes
  PATH=$command_dir:$PATH
  export PATH
  [ "$sysroot" != / ] && [ "$(stat -c %a "$sysroot")" = 700 ] && [ "$(stat -c %a "$command_dir")" = 700 ] || die 'Test paths must be private fixture directories.'
fi
[ "$(id -u)" = 0 ] || die 'This explicit operation requires root.'
[ -f "$sysroot/etc/alpine-release" ] && [ ! -L "$sysroot/etc/alpine-release" ] || die 'Only installed Alpine/OpenRC systems are supported.'
for tool in rc-service rc-update supervise-daemon adduser addgroup sha256sum stat sync cmp flock; do
  command -v "$tool" >/dev/null 2>&1 || die 'A required Alpine/OpenRC tool is unavailable.'
done

program=$sysroot/usr/local/libexec/macopenvm-agent
credentials=$sysroot/etc/macopenvm-agent
service=$sysroot/etc/init.d/macopenvm-agent
state=$sysroot/var/lib/macopenvm-agent
lock=$sysroot/var/lib/macopenvm-agent.install-lock
runlevel=$sysroot/etc/runlevels/default/macopenvm-agent
conf=$sysroot/etc/conf.d/macopenvm-agent
logfile=$sysroot/run/macopenvm-agent.log
log_owner=$sysroot/run/macopenvm-agent.log.owner
reservation=$sysroot/var/lib/macopenvm-agent-account
if [ -e "$reservation" ] || [ -L "$reservation" ]; then read_reservation; fi
kernel_lock=$sysroot/var/lib/macopenvm-agent.kernel-lock
program_next=$program.next; program_previous=$program.previous; program_failed=$program.failed
state_next=$state.next; state_previous=$state.previous; state_failed=$state.failed
retirement=$state.retirement; retirement_stage=$retirement.next; program_retired=$program.retired; state_retired=$state.retired
# Reject unsupported legacy state before creating even the permanent lock inode.
if [ -e "$state" ] || [ -L "$state" ]; then owned_state_contract; fi
regular_bounded "$0" 131072; no_symlink_ancestors "$0"
manager_hash=$(hash_of "$0")
if [ -d "$state" ]; then [ "$generation_manager" = "$manager_hash" ] || die 'Legacy or mixed manager state is unsupported.'; fi
# /var/lib must already exist. No tool is installed and no parent is created to
# obtain exclusion. The descriptor, not this pathname or a PID, owns the lock.
plain_directory "$sysroot/var/lib"; parent_safe "$kernel_lock"
if [ ! -e "$kernel_lock" ] && [ ! -L "$kernel_lock" ]; then
  (set -C; : >"$kernel_lock") || die 'The permanent exclusion inode could not be created.'
  chmod 600 "$kernel_lock"
fi
[ -f "$kernel_lock" ] && [ ! -L "$kernel_lock" ] && [ "$(stat -c %h "$kernel_lock")" = 1 ] \
  && [ "$(stat -c %a "$kernel_lock")" = 600 ] && [ "$(stat -c %s "$kernel_lock")" = 0 ] || die 'The permanent exclusion inode changed.'
owner_is "$kernel_lock" 0
exec 9<>"$kernel_lock"
flock -n 9 || die 'Another setup process holds kernel exclusion.'
[ "$(stat -L -c '%d:%i' /dev/fd/9)" = "$(stat -c '%d:%i' "$kernel_lock")" ] || die 'Kernel exclusion inode identity changed.'
# The permanent inode is never removed/replaced, including on failure/uninstall.
# This private reservation survives both uninstall modes. An old account without
# this exact record is never migrated/adopted; account/group files are not repaired.
for target in "$program" "$credentials" "$service" "$state" "$lock" "$runlevel" "$conf" "$logfile" "$log_owner" "$reservation"; do parent_safe "$target"; done
assert_absent "$conf"
if [ "$action" = retire-failed ]; then
  [ -n "$retirement_id" ] || die 'Retirement requires its explicit UUID.'
  [ "$(normalize_vm_id "$retirement_id")" = "$retirement_id" ] || die 'Retirement UUID is invalid.'
else [ -z "$retirement_id" ] || die 'Only retirement accepts a retirement UUID.'; fi
for target in "$retirement" "$retirement_stage" "$program_retired" "$state_retired"; do parent_safe "$target"; done
retirement_inventory

if [ "$action" = install ] || [ "$action" = reinstall ]; then
  [ -z "$retirement_id" ] && [ -z "$expected_generation" ] && [ -z "$target_generation" ] && [ "$resume" = no ] || die 'Install does not accept generation transaction options.'
  for target in "$program_next" "$program_previous" "$program_failed" "$state_next" "$state_previous" "$state_failed"; do assert_absent "$target"; done
  [ -n "$payload" ] && [ -n "$pin" ] && [ "$remove_credentials" = no ] || die 'Install requires a payload pin and an explicit credential mode.'
  if [ "$action" = install ]; then
    [ -n "$enrollment" ] && [ -z "$expected_vm" ] && [ "$reuse_credentials" = no ] || die 'Fresh install requires separate enrollment only.'
    assert_absent "$reservation"
  else
    [ -n "$expected_vm" ] || die 'Reinstall requires its expected VM UUID.'
    expected_vm=$(normalize_vm_id "$expected_vm")
    read_reservation
    [ "$expected_vm" = "$reserved_vm" ] || die 'The account reservation belongs to another VM.'
    if [ "$reuse_credentials" = yes ]; then
      [ -z "$enrollment" ] && [ "$reservation_status" = retained ] || die 'Only exact retained credentials may be explicitly reused.'
      owned_state_contract
      [ "$owned_uid:$owned_gid" = "$uid:$gid" ] && [ "$generation_vm" = "$reserved_vm" ] && [ "$generation_previous" = - ] || die 'Retained ownership and reservation disagree.'
      reservation_credentials
      (cd "$credentials" && sha256sum -c "$state/enrollment.sha256" >/dev/null 2>&1) || die 'Retained credentials changed.'
      enrollment=$credentials
    else
      [ -n "$enrollment" ] && [ "$reservation_status" = removed ] || die 'Re-enrollment requires prior explicit credential removal.'
      assert_absent "$credentials"; assert_absent "$state"
    fi
  fi
  [ "${#pin}" = 64 ] && printf '%s\n' "$pin" | awk '/^[0-9a-f]+$/ {ok=1} END {exit !ok}' || die 'The trusted manifest pin must be 64 lowercase hex digits.'
  plain_directory "$payload"; plain_directory "$enrollment"
  if [ -e "$payload/manifest.sig" ] || [ -e "$payload/issuer.raw" ]; then
    expect_names "$payload" "$(printf 'SHA256SUMS\nagent\ninitd\nissuer.raw\nmanifest.sig\nsetup.sh')"
    regular_bounded "$payload/manifest.sig" 64
    regular_bounded "$payload/issuer.raw" 32
    [ "$(stat -c %s "$payload/manifest.sig")" = 64 ] && [ "$(stat -c %s "$payload/issuer.raw")" = 32 ] || die 'Publisher metadata has an unexpected size.'
  else
    expect_names "$payload" "$(printf 'SHA256SUMS\nagent\ninitd\nsetup.sh')"
  fi
  expect_names "$enrollment" "$(printf 'ca.pem\ncert.pem\nkey.pem\nvm-id')"
  [ "$(stat -c %a "$enrollment")" = 700 ] && [ "$(stat -c %a "$enrollment/key.pem")" = 600 ] || die 'Enrollment and its private key must have private modes.'
  if [ "$reuse_credentials" = no ]; then
    owner_is "$enrollment" 0
    for file in cert.pem key.pem ca.pem vm-id; do owner_is "$enrollment/$file" 0; done
  fi
  regular_bounded "$payload/agent" 16777216
  regular_bounded "$payload/initd" 16384
  regular_bounded "$payload/setup.sh" 131072
  manifest_ok "$payload/SHA256SUMS"
  [ "$(hash_of "$payload/SHA256SUMS")" = "$pin" ] || die 'The exact manifest does not match the caller-approved pin.'
  for file in cert.pem key.pem ca.pem; do regular_bounded "$enrollment/$file" 65536; done
  valid_vm_id "$enrollment/vm-id"
  enrolled_vm=$(normalize_vm_id "$(cat "$enrollment/vm-id")")
  if [ "$action" = reinstall ]; then [ "$enrolled_vm" = "$reserved_vm" ] || die 'Enrollment belongs to another reserved VM.'; fi
  # Existing executable ancestors keep their policy. The dedicated UID needs traversal;
  # private credential/state directories are deliberately outside this check.
  program_parents_traversable
  for target in "$program" "$service" "$lock" "$runlevel" "$logfile" "$log_owner" "$sysroot/run/macopenvm-agent.pid"; do assert_absent "$target"; done
  if [ "$reuse_credentials" = no ]; then assert_absent "$credentials"; assert_absent "$state"; fi
  if [ "$action" = install ]; then
    ! id macopenvm-agent >/dev/null 2>&1 || die 'The service account already exists; preserve it and inspect the conflict.'
    ! grep -q '^macopenvm-agent:' "$sysroot/etc/group" || die 'The service group already exists; preserve it and inspect the conflict.'
  fi
  for target in "$program" "$credentials" "$service" "$state" "$runlevel" "$conf" "$logfile" "$reservation"; do ensure_parent "$target"; done
  program_parents_traversable
  mkdir -m 700 "$lock" || die 'Another or interrupted install owns the transaction lock.'
  stage=$(mktemp -d "$sysroot/var/lib/.macopenvm-agent-stage.XXXXXX") || die 'Private staging could not be created.'
  for target in "$program" "$credentials" "$service" "$state"; do
    [ "$(stat -c %d "$stage")" = "$(stat -c %d "${target%/*}")" ] || die 'Install publication requires one filesystem.'
  done
  # No failure trap removes state: interrupted staging and partial commits remain reviewable.
  copy_bounded "$payload/agent" "$stage/agent" 16777216
  copy_bounded "$payload/initd" "$stage/initd" 16384
  copy_bounded "$payload/setup.sh" "$stage/setup.sh" 131072
  copy_bounded "$payload/SHA256SUMS" "$stage/SHA256SUMS" 512
  manifest_ok "$stage/SHA256SUMS"
  [ "$(hash_of "$stage/SHA256SUMS")" = "$pin" ] || die 'Staged manifest verification failed; staging is preserved.'
  (cd "$stage" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || die 'Staged payload verification failed; staging is preserved.'
  [ "$(hash_of "$stage/setup.sh")" = "$manager_hash" ] || die 'The payload manager differs from the executing manager.'
  mkdir -m 700 "$stage/program" "$stage/credentials" "$stage/state"
  cp "$stage/agent" "$stage/program/macopenvm-agent"
  cp "$stage/setup.sh" "$stage/program/setup.sh"
  for file in cert.pem key.pem ca.pem vm-id; do copy_bounded "$enrollment/$file" "$stage/credentials/$file" 65536; chmod 600 "$stage/credentials/$file"; done
  chmod 400 "$stage/credentials/cert.pem" "$stage/credentials/ca.pem"
  valid_vm_id "$stage/credentials/vm-id"
  for file in cert.pem key.pem ca.pem vm-id; do
    [ "$(hash_of "$enrollment/$file")" = "$(hash_of "$stage/credentials/$file")" ] || die 'Enrollment changed during staging; staging is preserved.'
  done
  cp "$stage/SHA256SUMS" "$stage/state/payload.sha256"
  (cd "$stage/credentials" && sha256sum cert.pem key.pem ca.pem vm-id) > "$stage/state/enrollment.sha256"
  chmod 755 "$stage/program" "$stage/program/macopenvm-agent" "$stage/program/setup.sh" "$stage/initd"
  for file in program credentials state initd; do
    case "$file" in program) target=$program ;; credentials) target=$credentials ;; state) target=$state ;; initd) target=$service ;; esac
    [ "$(stat -c %d "$stage/$file")" = "$(stat -c %d "${target%/*}")" ] || die 'Install sources must remain on their destination filesystem.'
  done
  if [ "$action" = install ]; then
    addgroup -S macopenvm-agent >/dev/null 2>&1 || die 'Account provisioning failed; staging is preserved.'
    adduser -S -D -H -h /nonexistent -s /sbin/nologin -G macopenvm-agent macopenvm-agent >/dev/null 2>&1 || die 'Account provisioning failed; staging is preserved.'
    uid=$(id -u macopenvm-agent); gid=$(id -g macopenvm-agent)
    [ "$uid" -gt 0 ] && [ "$gid" -gt 0 ] || die 'The service identity must be unprivileged.'
    account_contract
    reserved_vm=$enrolled_vm
    reserved_passwd=$account_passwd; reserved_shadow=$account_shadow; reserved_group=$account_group
    mkdir -m 700 "$reservation"
  fi
  chown -R "$uid:$gid" "$stage/credentials" >/dev/null 2>&1 || die 'Credential ownership failed; staging is preserved.'
  chown -R 0:0 "$stage/program" "$stage/state" >/dev/null 2>&1 || die 'Program ownership failed; staging is preserved.'
  chown 0:0 "$stage/initd" >/dev/null 2>&1 || die 'Service ownership failed; staging is preserved.'
  printf 'macopenvm-agent-owned-v2\nmanifest-sha256=%s\nservice-uid=%s\nservice-gid=%s\n' "$pin" "$uid" "$gid" > "$stage/state/owner"
  generation_vm=$enrolled_vm; generation_pin=$pin; generation_previous=-
  generation_manager=$manager_hash; generation_initd=$(manifest_hash "$stage/SHA256SUMS" 2)
  generation_text >"$stage/state/generation"
  chmod 600 "$stage/state/generation"
  chmod 600 "$stage/state/owner" "$stage/state/payload.sha256" "$stage/state/enrollment.sha256"
  reserved_cert=$(hash_of "$stage/credentials/cert.pem"); reserved_key=$(hash_of "$stage/credentials/key.pem")
  reserved_ca=$(hash_of "$stage/credentials/ca.pem"); reserved_vm_hash=$(hash_of "$stage/credentials/vm-id")
  reservation_status=installed
  write_reservation
  # Legacy fresh staging uses one directory, so prove every publication stays
  # on this filesystem before the first rename. Cross-filesystem installs refuse.
  for target in "$program" "$credentials" "$service" "$state"; do
    [ "$(stat -c %d "$stage")" = "$(stat -c %d "${target%/*}")" ] || die 'Install publication requires one filesystem.'
  done
  # These are separate atomic renames, not one compound or power-loss transaction.
  # An error retains its lock, complete staged state and any previous retained state.
  if [ "$reuse_credentials" = yes ]; then rename_generation "$state" "$stage/retained-state"; fi
  rename_generation "$stage/state" "$state"
  rename_generation "$stage/program" "$program"
  if [ "$reuse_credentials" = no ]; then rename_generation "$stage/credentials" "$credentials"; fi
  rename_generation "$stage/initd" "$service"
  rc-update add macopenvm-agent default >/dev/null 2>&1 9>&- || die 'Service enablement failed; owned files are preserved for recovery.'
  rc-service macopenvm-agent start >/dev/null 2>&1 9>&- || die 'Service start failed; owned files are preserved for recovery.'
  if [ "$reuse_credentials" = yes ]; then
    for file in cert.pem key.pem ca.pem vm-id; do rm "$stage/credentials/$file"; done
    rmdir "$stage/credentials"
  fi
  for file in agent setup.sh SHA256SUMS; do rm "$stage/$file"; done
  if [ -d "$stage/retained-state" ]; then
    for file in owner payload.sha256 enrollment.sha256 generation; do rm "$stage/retained-state/$file"; done
    rmdir "$stage/retained-state"
  fi
  rmdir "$stage" "$lock"
  printf '%s\n' 'Experimental agent installed. A running service is not authenticated health evidence.'
  exit 0
fi

layout_shape() {
  # Four namespace moves: source program/state to retained slots, target
  # program/state to current. Exactly one pre/post boundary is admissible.
  local step source_program source_state target_program target_state candidate
  step=$1
  if [ "$transaction_operation" = upgrade ]; then
    saved_program=$program_previous; saved_state=$state_previous
    incoming_program=$program_next; incoming_state=$state_next
    for candidate in "$program_failed" "$state_failed"; do ! path_present "$candidate" || return 1; done
  else
    saved_program=$program_failed; saved_state=$state_failed
    incoming_program=$program_previous; incoming_state=$state_previous
    for candidate in "$program_next" "$state_next"; do ! path_present "$candidate" || return 1; done
  fi
  source_program=$program; source_state=$state
  target_program=$incoming_program; target_state=$incoming_state
  [ "$step" -lt 1 ] || source_program=$saved_program
  [ "$step" -lt 2 ] || source_state=$saved_state
  [ "$step" -lt 3 ] || target_program=$program
  [ "$step" -lt 4 ] || target_state=$state
  for candidate in "$source_program" "$source_state" "$target_program" "$target_state"; do path_present "$candidate" || return 1; done
  if [ "$step" -lt 1 ]; then ! path_present "$saved_program" || return 1; fi
  if [ "$step" -lt 2 ]; then ! path_present "$saved_state" || return 1; fi
  if [ "$step" = 1 ] || [ "$step" = 2 ]; then ! path_present "$program" || return 1; fi
  if [ "$step" = 2 ] || [ "$step" = 3 ]; then ! path_present "$state" || return 1; fi
  if [ "$step" -ge 3 ]; then ! path_present "$incoming_program" || return 1; fi
  if [ "$step" -ge 4 ]; then ! path_present "$incoming_state" || return 1; fi
  layout_source_program=$source_program; layout_source_state=$source_state
  layout_target_program=$target_program; layout_target_state=$target_state
}
validate_layout() {
  local first last step matched
  case "$transaction_phase" in
    prepared|stop) first=0; last=0 ;;
    save-program) first=0; last=1 ;;
    save-state) first=1; last=2 ;;
    publish-program) first=2; last=3 ;;
    publish-state) first=3; last=4 ;;
    start|complete) first=4; last=4 ;;
  esac
  matched=no; step=$first
  while [ "$step" -le "$last" ]; do
    if layout_shape "$step"; then matched=yes; layout_step=$step; break; fi
    step=$((step+1))
  done
  [ "$matched" = yes ] || die 'The journal namespace does not match its exact phase.'
  owned_state_at "$layout_source_state"
  [ "$owned_pin" = "$transaction_source" ] && [ "$(state_digest "$layout_source_state")" = "$transaction_source_state" ] || die 'The source generation evidence changed.'
  compatible_state "$layout_source_state"
  if [ "$transaction_operation" = upgrade ]; then
    [ "$generation_previous" = - ] || die 'The previous generation slot is already occupied.'
  else [ "$generation_previous" = "$transaction_target" ] || die 'Rollback source does not identify its previous generation.'; fi
  program_at "$layout_source_program" "$layout_source_state/payload.sha256"
  owned_state_at "$layout_target_state"
  [ "$owned_pin" = "$transaction_target" ] && [ "$(state_digest "$layout_target_state")" = "$transaction_target_state" ] || die 'The target generation evidence changed.'
  compatible_state "$layout_target_state"
  if [ "$transaction_operation" = upgrade ]; then
    [ "$generation_previous" = "$transaction_source" ] || die 'The target does not identify its retained previous generation.'
  else [ "$generation_previous" = - ] || die 'The rollback target is not the original previous generation.'; fi
  program_at "$layout_target_program" "$layout_target_state/payload.sha256"
}
service_files_contract() {
  regular_bounded "$service" 16384; owner_is "$service" 0
  [ "$(stat -c %a "$service")" = 755 ] || die 'Service permissions changed.'
  [ -L "$runlevel" ] || die 'The owned default runlevel entry is absent.'
  link=$(readlink "$runlevel")
  [ "$link" = "$service" ] || [ "$link" = ../../init.d/macopenvm-agent ] || die 'The default runlevel entry is unrelated.'
  if path_present "$logfile" || path_present "$log_owner"; then
    regular_bounded "$log_owner" 128; owner_is "$log_owner" 0
    [ -f "$logfile" ] && [ ! -L "$logfile" ] && [ "$(stat -c %h "$logfile")" = 1 ] || die 'The runtime log conflicts with owned state.'
    owner_is "$logfile" "$uid"
    [ "$(stat -c %a "$logfile")" = 600 ] && [ "$(stat -c %a "$log_owner")" = 600 ] || die 'Runtime log permissions changed.'
    [ "$(cat "$log_owner")" = "macopenvm-agent-log-v1:$(stat -c '%d:%i' "$logfile")" ] || die 'The runtime log inode changed.'
  fi
}
resume_transaction() {
  validate_layout
  [ "$transaction_phase" != complete ] || { printf '%s\n' 'Experimental generation transaction is already complete; retained evidence is preserved.'; return; }
  # A historical stop/start acknowledgement is never sufficient for recovery.
  # Reconstruct only the admitted layout, then validate the whole target before
  # starting. No failure path restarts or silently rolls back a generation.
  if [ "$transaction_phase" = prepared ]; then write_phase stop; fi
  normal_stop
  validate_layout
  while [ "$layout_step" -lt 4 ]; do
    service_quiescent
    case "$layout_step" in
      0) [ "$transaction_phase" = save-program ] || write_phase save-program; rename_generation "$program" "$saved_program" ;;
      1) [ "$transaction_phase" = save-state ] || write_phase save-state; rename_generation "$state" "$saved_state" ;;
      2) [ "$transaction_phase" = publish-program ] || write_phase publish-program; rename_generation "$incoming_program" "$program" ;;
      3) [ "$transaction_phase" = publish-state ] || write_phase publish-state; rename_generation "$incoming_state" "$state" ;;
    esac
    layout_step=$((layout_step+1))
    # The post-rename namespace is synchronized before the next durable phase.
  done
  [ "$transaction_phase" = start ] || write_phase start
  validate_layout
  service_quiescent
  rc-service macopenvm-agent start >/dev/null 2>&1 9>&- || die 'Generation start failed; current and previous evidence are preserved.'
  write_phase complete
  validate_layout
  printf '%s\n' 'Experimental generation transaction completed. Service start is not authenticated health evidence.'
}

if [ "$action" = retire-failed ]; then
  [ -n "$expected_vm" ] && [ -n "$expected_generation" ] && [ -n "$target_generation" ] \
    && [ -z "$payload" ] && [ -z "$pin" ] && [ -z "$enrollment" ] \
    && [ "$reuse_credentials:$remove_credentials" = no:no ] || die 'Retirement requires only its explicit VM, generation and UUID pins.'
  expected_vm=$(normalize_vm_id "$expected_vm"); valid_hash "$expected_generation"; valid_hash "$target_generation"
  [ "$expected_generation" != "$target_generation" ] || die 'Retirement generations must differ.'
  read_reservation
  [ "$expected_vm" = "$reserved_vm" ] && [ "$reservation_status" = installed ] || die 'Retirement requires the exact installed reservation.'
  reservation_credentials; program_parents_traversable; service_files_contract
  program_archive=$program_retired/$retirement_id; state_archive=$state_retired/$retirement_id
  if [ "$resume" = yes ]; then
    if path_present "$retirement_stage"; then publish_prepared_retirement; fi
    if path_present "$retirement"; then
      assert_absent "$state_archive/retirement"
      read_retirement; resume_retirement
    else
      # A failed final rename flush leaves a complete-looking archived journal
      # without confirmation; it cannot release other mutators or imply success.
      confirm_retirement; retirement_complete_archive "$retirement_id"
      printf '%s\n' 'Experimental retirement completion confirmed; retained evidence is unchanged.'
    fi
  else
    assert_absent "$retirement"; assert_absent "$retirement_stage"; assert_absent "$program_archive"; assert_absent "$state_archive"
    [ "$retirement_count" -lt 8 ] || die 'Retirement archive capacity is full; no evidence is pruned.'
    read_transaction
    [ "$transaction_operation:$transaction_phase:$transaction_source:$transaction_target" = \
      "rollback:complete:$target_generation:$expected_generation" ] || die 'Retirement requires the exact completed rollback.'
    assert_absent "$lock/transaction.next"
    validate_layout
    [ "$layout_step" = 4 ] && [ -f "$lock/previous-transaction" ] || die 'Retirement requires the complete matching cohort.'
    rt_vm=$reserved_vm; rt_id=$retirement_id; rt_current=$expected_generation; rt_failed=$target_generation
    rt_manager=$manager_hash; rt_initd=$(hash_of "$service"); rt_uid=$uid; rt_gid=$gid
    rt_reservation=$(hash_of "$reservation/record")
    rt_current_state=$transaction_target_state; rt_failed_state=$transaction_source_state
    rt_current_program_inode=$(retirement_inode "$program"); rt_current_state_inode=$(retirement_inode "$state")
    rt_failed_program_inode=$(retirement_inode "$program_failed"); rt_failed_state_inode=$(retirement_inode "$state_failed")
    rt_cohort_inode=$(retirement_inode "$lock"); rt_cohort=; rt_phase=prepared
    retirement_cohort "$lock"; retirement_caller; retirement_layout
    mkdir -m 700 "$retirement_stage"
    retirement_text >"$retirement_stage/record"; chmod 600 "$retirement_stage/record"
    publish_prepared_retirement; resume_retirement
  fi
  exit 0
fi

if [ "$action" = upgrade ] || [ "$action" = rollback ] || [ "$action" = recover ]; then
  [ -z "$retirement_id" ] && [ -n "$expected_vm" ] && [ -n "$expected_generation" ] && [ -z "$enrollment" ] \
    && [ "$reuse_credentials:$remove_credentials" = no:no ] || die 'Generation operations require exact VM and generation pins only.'
  expected_vm=$(normalize_vm_id "$expected_vm"); valid_hash "$expected_generation"
  read_reservation
  [ "$expected_vm" = "$reserved_vm" ] && [ "$reservation_status" = installed ] || die 'The exact installed reservation is required.'
  reservation_credentials; program_parents_traversable; service_files_contract
  if [ "$action" = upgrade ]; then
    [ -n "$payload" ] && [ -n "$pin" ] && [ -z "$target_generation" ] && [ "$resume" = no ] || die 'Upgrade requires its exact approved target payload.'
    valid_hash "$pin"; [ "$pin" != "$expected_generation" ] || die 'Upgrade generations must differ.'
    for target in "$lock" "$program_next" "$program_previous" "$program_failed" "$state_next" "$state_previous" "$state_failed"; do assert_absent "$target"; done
    owned_state_contract; compatible_state "$state"; program_at "$program" "$state/payload.sha256"
    [ "$owned_pin" = "$expected_generation" ] && [ "$generation_previous" = - ] || die 'The expected source or previous slot changed.'
    transaction_source=$owned_pin; transaction_source_state=$(state_digest "$state")
    plain_directory "$payload"
    if path_present "$payload/manifest.sig" || path_present "$payload/issuer.raw"; then
      expect_names "$payload" "$(printf 'SHA256SUMS\nagent\ninitd\nissuer.raw\nmanifest.sig\nsetup.sh')"
      regular_bounded "$payload/manifest.sig" 64; regular_bounded "$payload/issuer.raw" 32
      [ "$(stat -c %s "$payload/manifest.sig")" = 64 ] && [ "$(stat -c %s "$payload/issuer.raw")" = 32 ] || die 'Publisher metadata has an unexpected size.'
    else expect_names "$payload" "$(printf 'SHA256SUMS\nagent\ninitd\nsetup.sh')"; fi
    manifest_ok "$payload/SHA256SUMS"
    [ "$(hash_of "$payload/SHA256SUMS")" = "$pin" ] || die 'The target manifest does not match the approved pin.'
    regular_bounded "$payload/agent" 16777216; regular_bounded "$payload/initd" 16384; regular_bounded "$payload/setup.sh" 131072
    (cd "$payload" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || die 'The target payload changed.'
    [ "$(manifest_hash "$payload/SHA256SUMS" 3)" = "$manager_hash" ] \
      && [ "$(manifest_hash "$payload/SHA256SUMS" 2)" = "$(hash_of "$service")" ] || die 'Mixed manager or service generations are unsupported.'
    # Each prepared tree is a direct sibling of its destination; credentials
    # and the account reservation are referenced and never copied or rewritten.
    mkdir -m 755 "$program_next"; mkdir -m 700 "$state_next"
    copy_bounded "$payload/agent" "$program_next/macopenvm-agent" 16777216
    copy_bounded "$payload/setup.sh" "$program_next/setup.sh" 131072
    chmod 755 "$program_next/macopenvm-agent" "$program_next/setup.sh"
    copy_bounded "$payload/SHA256SUMS" "$state_next/payload.sha256" 512
    cp "$state/enrollment.sha256" "$state_next/enrollment.sha256"
    printf 'macopenvm-agent-owned-v2\nmanifest-sha256=%s\nservice-uid=%s\nservice-gid=%s\n' "$pin" "$uid" "$gid" >"$state_next/owner"
    generation_vm=$reserved_vm; generation_pin=$pin; generation_previous=$transaction_source
    generation_manager=$manager_hash; generation_initd=$(hash_of "$service")
    generation_text >"$state_next/generation"
    chmod 600 "$state_next/owner" "$state_next/payload.sha256" "$state_next/enrollment.sha256" "$state_next/generation"
    chown -R 0:0 "$program_next" "$state_next" >/dev/null 2>&1 || die 'Generation staging ownership failed.'
    transaction_target=$pin; transaction_target_state=$(state_digest "$state_next")
    transaction_operation=upgrade; transaction_reservation=$(hash_of "$reservation/record")
    transaction_phase=prepared; validate_layout
    for file in "$program_next/macopenvm-agent" "$program_next/setup.sh" "$state_next/owner" "$state_next/payload.sha256" "$state_next/enrollment.sha256" "$state_next/generation"; do sync "$file"; done
    sync "$program_next"; sync "$state_next"; sync "${program%/*}"; sync "${state%/*}"
    mkdir -m 700 "$lock"; write_phase prepared; write_phase stop
    resume_transaction
  elif [ "$action" = rollback ]; then
    [ -z "$payload" ] && [ -z "$pin" ] && [ -n "$target_generation" ] && [ "$resume" = no ] || die 'Rollback requires its exact retained target pin.'
    valid_hash "$target_generation"
    read_transaction
    [ "$transaction_operation" = upgrade ] && { [ "$transaction_phase" = start ] || [ "$transaction_phase" = complete ]; } \
      && [ "$transaction_source:$transaction_target" = "$target_generation:$expected_generation" ] || die 'Rollback requires the exact published upgrade and previous generation.'
    validate_layout
    for target in "$program_next" "$state_next" "$program_failed" "$state_failed" "$lock/previous-transaction"; do assert_absent "$target"; done
    # Preserve the reviewed failed/completed upgrade record before replacing it.
    cp "$lock/transaction" "$lock/previous-transaction"; chmod 600 "$lock/previous-transaction"; sync "$lock/previous-transaction"; sync "$lock"
    old_source_state=$transaction_source_state
    transaction_source=$expected_generation; transaction_target=$target_generation
    transaction_source_state=$transaction_target_state; transaction_target_state=$old_source_state
    transaction_operation=rollback; write_phase prepared; write_phase stop
    resume_transaction
  else
    [ -z "$payload" ] && [ -z "$pin" ] && [ -n "$target_generation" ] && [ "$resume" = yes ] || die 'Recovery requires explicit resume and the exact journal pins.'
    valid_hash "$target_generation"; read_transaction
    [ "$transaction_source:$transaction_target" = "$expected_generation:$target_generation" ] || die 'Recovery generation pins do not match the journal.'
    resume_transaction
  fi
  exit 0
fi

[ -z "$retirement_id" ] && [ -z "$payload" ] && [ -z "$pin" ] && [ -z "$enrollment" ] && [ -z "$expected_vm" ] \
  && [ -z "$expected_generation" ] && [ -z "$target_generation" ] && [ "$resume" = no ] && [ "$reuse_credentials" = no ] || die 'Uninstall does not accept installation inputs.'
# Generation evidence has no implicit deletion policy. Uninstall is refused until
# an explicit policy for retiring these owned rollback records is approved.
for target in "$program_next" "$program_previous" "$program_failed" "$state_next" "$state_previous" "$state_failed"; do assert_absent "$target"; done
owned_state_contract
[ "$generation_manager" = "$manager_hash" ] || die 'Mixed manager generations are unsupported.'
pin=$owned_pin; uid=$owned_uid; gid=$owned_gid
[ "$(id -u macopenvm-agent)" = "$uid" ] && [ "$(id -g macopenvm-agent)" = "$gid" ] || die 'The recorded account identity changed.'
plain_directory "$reservation"
has_reservation=no
if [ -e "$reservation" ] || [ -L "$reservation" ]; then
  state_uid=$uid; state_gid=$gid
  read_reservation
  [ "$uid:$gid" = "$state_uid:$state_gid" ] && [ "$generation_vm" = "$reserved_vm" ] || die 'Ownership and account reservation disagree.'
  [ "$reservation_status" = installed ] || [ "$reservation_status" = retained ] || die 'Reservation and owned installation state disagree.'
  if [ -e "$credentials" ] || [ -L "$credentials" ]; then reservation_credentials; fi
  has_reservation=yes
fi
if [ -e "$program" ] || [ -L "$program" ]; then program_at "$program" "$state/payload.sha256"; fi
if [ -e "$service" ] || [ -L "$service" ]; then
  regular_bounded "$service" 16384; owner_is "$service" 0
  [ "$(stat -c %a "$service")" = 755 ] && [ "$(hash_of "$service")" = "$(manifest_hash "$state/payload.sha256" 2)" ] || die 'The service definition changed; preserve existing state.'
fi
if [ -e "$credentials" ] || [ -L "$credentials" ]; then
  plain_directory "$credentials"; owner_is "$credentials" "$uid"
  [ "$(stat -c %a "$credentials")" = 700 ] || die 'Credential directory permissions changed.'
  expect_names "$credentials" "$(printf 'ca.pem\ncert.pem\nkey.pem\nvm-id')"
  regular_bounded "$state/enrollment.sha256" 512; owner_is "$state/enrollment.sha256" 0
  enrollment_manifest_ok "$state/enrollment.sha256"
  for file in cert.pem key.pem ca.pem vm-id; do
    case "$file" in cert.pem|ca.pem) mode=400 ;; *) mode=600 ;; esac
    regular_bounded "$credentials/$file" 65536; owner_is "$credentials/$file" "$uid"
    [ "$(stat -c %a "$credentials/$file")" = "$mode" ] || die 'Credential permissions changed.'
  done
  (cd "$credentials" && sha256sum -c "$state/enrollment.sha256" >/dev/null 2>&1) || die 'Credentials changed; preserve existing state.'
fi
if [ -e "$runlevel" ] || [ -L "$runlevel" ]; then
  [ -L "$runlevel" ] || die 'A conflicting runlevel entry is present.'
  link=$(readlink "$runlevel")
  [ "$link" = "$service" ] || [ "$link" = ../../init.d/macopenvm-agent ] || die 'The runlevel entry is unrelated; preserve it.'
fi
if [ -e "$logfile" ] || [ -L "$logfile" ] || [ -e "$log_owner" ] || [ -L "$log_owner" ]; then
  regular_bounded "$log_owner" 128; owner_is "$log_owner" 0
  [ -f "$logfile" ] && [ ! -L "$logfile" ] && [ "$(stat -c %h "$logfile")" = 1 ] || die 'A runtime log conflicts with owned state.'
  owner_is "$logfile" "$uid"
  [ "$(stat -c %a "$logfile")" = 600 ] && [ "$(stat -c %a "$log_owner")" = 600 ] || die 'Runtime log permissions changed.'
  [ "$(cat "$log_owner")" = "macopenvm-agent-log-v1:$(stat -c '%d:%i' "$logfile")" ] || die 'The runtime log inode changed; preserve existing state.'
fi
[ ! -d "$lock" ] || [ ! -L "$lock" ] || die 'The transaction lock is a symbolic link.'
if [ -f "$service" ]; then normal_stop; fi
if [ -L "$runlevel" ]; then rc-update del macopenvm-agent default >/dev/null 2>&1 9>&- || die 'Service disablement failed; owned files are preserved.'; fi
if [ -f "$log_owner" ]; then rm "$logfile" "$log_owner"; fi
if [ -f "$service" ]; then rm "$service"; fi
if [ -d "$program" ]; then rm "$program/macopenvm-agent" "$program/setup.sh"; rmdir "$program"; fi
if [ "$remove_credentials" = yes ] && [ -d "$credentials" ]; then
  for file in cert.pem key.pem ca.pem vm-id; do rm "$credentials/$file"; done
  rmdir "$credentials"
fi
if [ ! -d "$credentials" ]; then rm "$state/owner" "$state/payload.sha256" "$state/enrollment.sha256" "$state/generation"; rmdir "$state"; fi
if [ "$has_reservation" = yes ]; then
  if [ -d "$credentials" ]; then reservation_status=retained;
  else reservation_status=removed; reserved_cert=-; reserved_key=-; reserved_ca=-; reserved_vm_hash=-; fi
  write_reservation
fi
# Do not remove interrupted staging, a lock, or any account: ownership beyond these exact files is unproven.
printf '%s\n' 'Experimental agent uninstalled. The dedicated locked nonlogin account is retained; interrupted staging is preserved.'
