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
    'uninstall [--remove-credentials]' \
    'Interrupted staging/commits are preserved. Inspect owned state before explicit uninstall recovery.' \
    'Uninstall leaves the dedicated locked, nonlogin service account in place.'
}

action= payload= pin= enrollment= sysroot= command_dir= expected_vm= remove_credentials=no reuse_credentials=no test_mode=no
while [ "$#" -gt 0 ]; do
  case "$1" in
    install|reinstall|uninstall) [ -z "$action" ] || die 'Specify one action.'; action=$1; shift ;;
    --payload|--manifest-sha256|--enrollment|--vm-id|--test-sysroot|--test-command-dir)
      [ "$#" -ge 2 ] || die 'An option value is missing.'
      case "$1" in
        --payload) [ -z "$payload" ] || die 'Duplicate option.'; payload=$2 ;;
        --manifest-sha256) [ -z "$pin" ] || die 'Duplicate option.'; pin=$2 ;;
        --enrollment) [ -z "$enrollment" ] || die 'Duplicate option.'; enrollment=$2 ;;
        --vm-id) [ -z "$expected_vm" ] || die 'Duplicate option.'; expected_vm=$2 ;;
        --test-sysroot) [ -z "$sysroot" ] || die 'Duplicate option.'; sysroot=$2 ;;
        --test-command-dir) [ -z "$command_dir" ] || die 'Duplicate option.'; command_dir=$2 ;;
      esac
      shift 2 ;;
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
hash_of() { sha256sum "$1" | awk '{print $1}'; }
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
  printf 'macopenvm-agent-account-v1\nvm-id=%s\nservice-uid=%s\nservice-gid=%s\npasswd-sha256=%s\nshadow-sha256=%s\ngroup-sha256=%s\ncredentials=%s\ncert-sha256=%s\nkey-sha256=%s\nca-sha256=%s\nvm-id-sha256=%s\n' \
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
  # Same-directory publication survives normal operation/reboot. A leftover next
  # record is a conflict, not authority to resume. No compound power-loss claim.
  local record_next
  record_next=$reservation/record.next
  assert_absent "$record_next"
  reservation_text >"$record_next"
  chmod 600 "$record_next"; owner_is "$record_next" 0
  sync "$record_next"
  mv "$record_next" "$reservation/record"
  sync "$reservation"
  reservation_text | cmp -s - "$reservation/record" || die 'Reservation publication could not be confirmed.'
}
owned_state_contract() {
  plain_directory "$state"; owner_is "$state" 0
  [ "$(stat -c %a "$state")" = 700 ] || die 'The ownership state is not private.'
  expect_names "$state" "$(printf 'enrollment.sha256\nowner\npayload.sha256')"
  regular_bounded "$state/owner" 256; owner_is "$state/owner" 0
  manifest_ok "$state/payload.sha256"
  owned_pin=$(hash_of "$state/payload.sha256")
  owned_uid=$(sed -n '3s/^service-uid=//p' "$state/owner"); owned_gid=$(sed -n '4s/^service-gid=//p' "$state/owner")
  case "$owned_uid:$owned_gid" in *[!0-9:]*|:*) die 'The ownership marker is invalid.';; esac
  [ "$owned_uid" -gt 0 ] && [ "$owned_gid" -gt 0 ] || die 'The ownership marker is invalid.'
  expected=$(printf 'macopenvm-agent-owned-v1\nmanifest-sha256=%s\nservice-uid=%s\nservice-gid=%s\n' "$owned_pin" "$owned_uid" "$owned_gid")
  [ "$(cat "$state/owner")" = "$expected" ] && [ "$(wc -l <"$state/owner" | tr -d ' ')" = 4 ] || die 'The exact ownership marker does not match.'
  for file in owner payload.sha256 enrollment.sha256; do
    regular_bounded "$state/$file" 512; owner_is "$state/$file" 0
    [ "$(stat -c %a "$state/$file")" = 600 ] || die 'Ownership record permissions changed.'
  done
  enrollment_manifest_ok "$state/enrollment.sha256"
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
for tool in rc-service rc-update supervise-daemon adduser addgroup sha256sum stat sync cmp; do
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
# This private reservation survives both uninstall modes. An old account without
# this exact record is never migrated/adopted; account/group files are not repaired.
for target in "$program" "$credentials" "$service" "$state" "$lock" "$runlevel" "$conf" "$logfile" "$log_owner" "$reservation"; do parent_safe "$target"; done
assert_absent "$conf"

if [ "$action" = install ] || [ "$action" = reinstall ]; then
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
      [ "$owned_uid:$owned_gid" = "$uid:$gid" ] || die 'Retained ownership and reservation disagree.'
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
  regular_bounded "$payload/setup.sh" 65536
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
  # No failure trap removes state: interrupted staging and partial commits remain reviewable.
  copy_bounded "$payload/agent" "$stage/agent" 16777216
  copy_bounded "$payload/initd" "$stage/initd" 16384
  copy_bounded "$payload/setup.sh" "$stage/setup.sh" 65536
  copy_bounded "$payload/SHA256SUMS" "$stage/SHA256SUMS" 512
  manifest_ok "$stage/SHA256SUMS"
  [ "$(hash_of "$stage/SHA256SUMS")" = "$pin" ] || die 'Staged manifest verification failed; staging is preserved.'
  (cd "$stage" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || die 'Staged payload verification failed; staging is preserved.'
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
  printf 'macopenvm-agent-owned-v1\nmanifest-sha256=%s\nservice-uid=%s\nservice-gid=%s\n' "$pin" "$uid" "$gid" > "$stage/state/owner"
  chmod 600 "$stage/state/owner" "$stage/state/payload.sha256" "$stage/state/enrollment.sha256"
  reserved_cert=$(hash_of "$stage/credentials/cert.pem"); reserved_key=$(hash_of "$stage/credentials/key.pem")
  reserved_ca=$(hash_of "$stage/credentials/ca.pem"); reserved_vm_hash=$(hash_of "$stage/credentials/vm-id")
  reservation_status=installed
  write_reservation
  # These are separate atomic renames, not one compound or power-loss transaction.
  # An error retains its lock, complete staged state and any previous retained state.
  if [ "$reuse_credentials" = yes ]; then mv "$state" "$stage/retained-state"; fi
  mv "$stage/state" "$state"
  mv "$stage/program" "$program"
  if [ "$reuse_credentials" = no ]; then mv "$stage/credentials" "$credentials"; fi
  mv "$stage/initd" "$service"
  rc-update add macopenvm-agent default >/dev/null 2>&1 || die 'Service enablement failed; owned files are preserved for recovery.'
  rc-service macopenvm-agent start >/dev/null 2>&1 || die 'Service start failed; owned files are preserved for recovery.'
  if [ "$reuse_credentials" = yes ]; then
    for file in cert.pem key.pem ca.pem vm-id; do rm "$stage/credentials/$file"; done
    rmdir "$stage/credentials"
  fi
  for file in agent setup.sh SHA256SUMS; do rm "$stage/$file"; done
  if [ -d "$stage/retained-state" ]; then
    for file in owner payload.sha256 enrollment.sha256; do rm "$stage/retained-state/$file"; done
    rmdir "$stage/retained-state"
  fi
  rmdir "$stage" "$lock"
  printf '%s\n' 'Experimental agent installed. A running service is not authenticated health evidence.'
  exit 0
fi

[ -z "$payload" ] && [ -z "$pin" ] && [ -z "$enrollment" ] && [ -z "$expected_vm" ] && [ "$reuse_credentials" = no ] || die 'Uninstall does not accept installation inputs.'
plain_directory "$state"; owner_is "$state" 0
[ "$(stat -c %a "$state")" = 700 ] || die 'The ownership state is not private.'
expect_names "$state" "$(printf 'enrollment.sha256\nowner\npayload.sha256')"
regular_bounded "$state/owner" 256; owner_is "$state/owner" 0
manifest_ok "$state/payload.sha256"
pin=$(hash_of "$state/payload.sha256")
uid=$(sed -n '3s/^service-uid=//p' "$state/owner")
gid=$(sed -n '4s/^service-gid=//p' "$state/owner")
case "$uid:$gid" in *[!0-9:]*|:*) die 'The ownership marker is invalid.' ;; esac
[ "$uid" -gt 0 ] && [ "$gid" -gt 0 ] || die 'The ownership marker is invalid.'
expected=$(printf 'macopenvm-agent-owned-v1\nmanifest-sha256=%s\nservice-uid=%s\nservice-gid=%s\n' "$pin" "$uid" "$gid")
[ "$(cat "$state/owner")" = "$expected" ] && [ "$(wc -l < "$state/owner" | tr -d ' ')" = 4 ] || die 'The exact ownership marker does not match.'
[ "$(id -u macopenvm-agent)" = "$uid" ] && [ "$(id -g macopenvm-agent)" = "$gid" ] || die 'The recorded account identity changed; preserve existing state.'
for file in owner payload.sha256 enrollment.sha256; do
  owner_is "$state/$file" 0
  [ "$(stat -c %a "$state/$file")" = 600 ] || die 'Ownership record permissions changed.'
done
has_reservation=no
if [ -e "$reservation" ] || [ -L "$reservation" ]; then
  state_uid=$uid; state_gid=$gid
  read_reservation
  [ "$uid:$gid" = "$state_uid:$state_gid" ] || die 'Ownership and account reservation disagree.'
  [ "$reservation_status" = installed ] || [ "$reservation_status" = retained ] || die 'Reservation and owned installation state disagree.'
  if [ -e "$credentials" ] || [ -L "$credentials" ]; then reservation_credentials; fi
  has_reservation=yes
fi
if [ -e "$program" ] || [ -L "$program" ]; then
  plain_directory "$program"; owner_is "$program" 0
  expect_names "$program" "$(printf 'macopenvm-agent\nsetup.sh')"
  for entry in 'macopenvm-agent:1' 'setup.sh:3'; do
    file=${entry%:*}; line=${entry#*:}
    regular_bounded "$program/$file" 16777216; owner_is "$program/$file" 0
    [ "$(hash_of "$program/$file")" = "$(manifest_hash "$state/payload.sha256" "$line")" ] || die 'An installed program changed; preserve existing state.'
  done
fi
if [ -e "$service" ] || [ -L "$service" ]; then
  regular_bounded "$service" 16384; owner_is "$service" 0
  [ "$(hash_of "$service")" = "$(manifest_hash "$state/payload.sha256" 2)" ] || die 'The service definition changed; preserve existing state.'
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
if [ -f "$service" ]; then rc-service macopenvm-agent stop >/dev/null 2>&1 || die 'Normal service stop failed; all owned files are preserved.'; fi
if [ -L "$runlevel" ]; then rc-update del macopenvm-agent default >/dev/null 2>&1 || die 'Service disablement failed; owned files are preserved.'; fi
if [ -f "$log_owner" ]; then rm "$logfile" "$log_owner"; fi
if [ -f "$service" ]; then rm "$service"; fi
if [ -d "$program" ]; then rm "$program/macopenvm-agent" "$program/setup.sh"; rmdir "$program"; fi
if [ "$remove_credentials" = yes ] && [ -d "$credentials" ]; then
  for file in cert.pem key.pem ca.pem vm-id; do rm "$credentials/$file"; done
  rmdir "$credentials"
fi
if [ ! -d "$credentials" ]; then rm "$state/owner" "$state/payload.sha256" "$state/enrollment.sha256"; rmdir "$state"; fi
if [ "$has_reservation" = yes ]; then
  if [ -d "$credentials" ]; then reservation_status=retained;
  else reservation_status=removed; reserved_cert=-; reserved_key=-; reserved_ca=-; reserved_vm_hash=-; fi
  write_reservation
fi
# Do not remove interrupted staging, a lock, or any account: ownership beyond these exact files is unproven.
printf '%s\n' 'Experimental agent uninstalled. The dedicated locked nonlogin account is retained; interrupted staging is preserved.'
