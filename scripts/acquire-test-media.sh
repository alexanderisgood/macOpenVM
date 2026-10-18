#!/bin/bash
set -euo pipefail
test "${1:-}" = --download || { echo 'Explicit --download is required (official ARM64 Linux image, local experiment only).'; exit 2; }
cd "$(dirname "$0")/.."
mkdir -p .lab/media
name=alpine-virt-3.24.2-aarch64.iso
expected=a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6
verify() { test "$(shasum -a 256 "$1" | cut -d ' ' -f 1)" = "$expected"; }
if test -f ".lab/media/$name"; then verify ".lab/media/$name"; exit; fi
temporary=$(mktemp .lab/media/download.XXXXXX)
trap 'rm -f "$temporary"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 --max-time 180 \
  "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/$name" -o "$temporary"
verify "$temporary"
mv -n "$temporary" ".lab/media/$name"
verify ".lab/media/$name"
echo 'Official Linux image checksum verified; retained only under ignored .lab/media.'
