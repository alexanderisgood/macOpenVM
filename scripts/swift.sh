#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
command=${1:?Use build or test}; shift
driver=$(xcrun --find swift)
compiler=$(xcrun --find swiftc)
toolchain_usr=$(dirname "$(dirname "$compiler")")
arguments=("$driver" "$command" --disable-sandbox --cache-path .build/cache --config-path .build/config
  --security-path .build/security)
if test -d "$toolchain_usr/lib/swift/host/plugins/testing"; then
  arguments+=(-Xswiftc -plugin-path -Xswiftc "$toolchain_usr/lib/swift/host/plugins/testing")
  if test -f "$toolchain_usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"; then
    arguments+=(-Xswiftc -load-plugin-library -Xswiftc "$toolchain_usr/lib/swift/host/plugins/testing/libTestingMacros.dylib")
  fi
fi
exec "${arguments[@]}" "$@"
