#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: bash $0 <DXMT source checkout> <native graphics prefix>" >&2
    exit 64
fi

fixture_dir=$(cd "$(dirname "$0")" && pwd -P)
wire_dir=$(cd "$fixture_dir/../../Backends/SharedFrameWire" && pwd -P)
dxmt_source=$(cd "$1" && pwd -P)
graphics_prefix=$(cd "$2" && pwd -P)
build_dir=$(mktemp -d /tmp/mvo-scanout-handoff.XXXXXXXX)
trap 'rm -rf -- "$build_dir"' EXIT

flags=(-arch arm64 -O2 -Wall -Wextra -Werror -I "$wire_dir/include")
xcrun clang++ "${flags[@]}" -std=c++20 -fms-extensions \
    -isystem "$dxmt_source/include/native/windows" \
    -isystem "$dxmt_source/include/native/directx" \
    -isystem "$dxmt_source/src/dxmt-native" \
    -isystem "$graphics_prefix/include" \
    -c "$fixture_dir/ScanoutDxmt.cpp" -o "$build_dir/ScanoutDxmt.o"
xcrun clang "${flags[@]}" -fno-objc-arc -Wno-unused-function \
    -c "$fixture_dir/ScanoutHandoff.m" -o "$build_dir/ScanoutHandoff.o"
for source in ScanoutLeasePool SharedHDRFrameTransport SharedHDRFrameWire; do
    xcrun clang "${flags[@]}" -c "$wire_dir/$source.c" -o "$build_dir/$source.o"
done
xcrun clang++ -arch arm64 "$build_dir"/*.o -L "$graphics_prefix/lib" -ldxmt-native \
    -Wl,-rpath,"$graphics_prefix/lib" -framework Foundation -framework Metal -lproc \
    -o "$build_dir/ScanoutHandoff"

"$build_dir/ScanoutHandoff" 2880x1800
"$build_dir/ScanoutHandoff" 3456x2168
