#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Cross-build only the original ARM64 Linux TLS lab; never run a guest or agent."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
PLATFORM = ROOT / ".lab/windows-platform-a77101301bb14ba085a3a6e4b4f070ab"
CLANG = Path("/opt/homebrew/Cellar/llvm/22.1.8/bin/clang-22")
CLANG_SHA = "305697d3868243dca6e4aabf4f628df7de135d701eb4fd78f6a5d7528fef4395"
LLD = PLATFORM / "tools/lld22/lld@22/22.1.8/bin/lld"
LLD_SHA = "7f629593760ab23657f57ad6b996b6d38c1ea922a5bcd02b4b27c3b5364d1f8c"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sysroot-fixture", type=Path, required=True)
    args = parser.parse_args()
    fixture = args.sysroot_fixture
    if (fixture.parent != ROOT / ".lab" or fixture.resolve() != fixture or
            re.fullmatch(r"linux-tls-sysroot-[0-9a-f]{32}", fixture.name) is None or
            stat.S_IMODE(fixture.stat().st_mode) != 0o700):
        raise RuntimeError("Choose the private verified sysroot fixture")
    record = json.loads((fixture / "result.json").read_text())
    if record["status"] != "sysroot-prepared" or len(record["packages"]) != 3:
        raise RuntimeError("Incomplete sysroot")
    if digest(CLANG) != CLANG_SHA or digest(LLD) != LLD_SHA:
        raise RuntimeError("Pinned tool changed")
    sysroot = fixture / "sysroot"
    build = fixture / ("build-" + uuid.uuid4().hex)
    build.mkdir(mode=0o700)
    source = ROOT / "GuestAgent/Linux/transport_tls_lab.c"
    header = ROOT / "GuestAgent/Protocol/generated/agent_v1.h"
    object_file = build / "transport_tls_lab.o"
    executable = build / "macopenvm-agent-tls-lab"
    compiler = [str(CLANG), "--target=aarch64-linux-musl", "--sysroot=" + str(sysroot),
                "-std=c11", "-O2", "-fPIE", "-fstack-protector-strong", "-D_FORTIFY_SOURCE=2",
                "-Wall", "-Wextra", "-Werror", "-Wpedantic", "-c", str(source), "-o", str(object_file)]
    linker = [str(LLD), "-flavor", "gnu", "--sysroot=" + str(sysroot), "-m", "aarch64elf",
              "-pie", "-dynamic-linker", "/lib/ld-musl-aarch64.so.1", "-z", "relro", "-z", "now",
              "-z", "noexecstack", str(sysroot / "usr/lib/Scrt1.o"), str(sysroot / "usr/lib/crti.o"),
              str(object_file), "-L" + str(sysroot / "usr/lib"), "-lssl", "-lcrypto", "-lc",
              str(sysroot / "usr/lib/crtn.o"), "-o", str(executable)]
    environment = {"PATH": "/usr/bin:/bin", "LC_ALL": "C",
                   "DYLD_LIBRARY_PATH": ":".join([str(PLATFORM / "tools/lld22/lld@22/22.1.8/lib"),
                                                   "/opt/homebrew/opt/llvm@22/lib",
                                                   "/opt/homebrew/opt/zstd/lib"])}
    operations = []
    for label, argv in (("compile", compiler), ("link", linker)):
        completed = subprocess.run(argv, cwd=build, env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, close_fds=True)
        save(build / (label + ".stdout"), completed.stdout)
        save(build / (label + ".stderr"), completed.stderr)
        operations.append({"label": label, "argv": argv, "exit": completed.returncode})
        if completed.returncode:
            print(completed.stderr.decode(errors="replace"))
            raise RuntimeError("Original guest build failed: " + label)
    os.chmod(executable, 0o500)
    result = {"schemaVersion": 1, "status": "built-not-executed", "operations": operations,
              "compilerSHA256": CLANG_SHA, "linkerSHA256": LLD_SHA,
              "sourceSHA256": digest(source), "protocolHeaderSHA256": digest(header),
              "binary": str(executable), "binaryBytes": executable.stat().st_size,
              "binarySHA256": digest(executable), "architecture": "aarch64-linux-musl",
              "guestStarted": False, "agentExecuted": False, "keysGenerated": False,
              "serviceCLI": "CERT KEY CA VM_UUID --service",
              "serviceRequiresNonRoot": True, "serviceCredentialDirectoryMode": "0700",
              "serviceKeyMode": "0600", "serviceCertificateMode": "0400",
              "serviceConnectionsPerMinute": 32, "serviceBadConnectionsPerMinute": 8,
              "serviceEventLogLimit": 64,
              "serviceRegularAppendLogByteLimit": 16384,
              "serviceRuntimeVerified": False}
    save(build / "result.json", json.dumps(result, indent=2, sort_keys=True).encode() + b"\n")
    print(json.dumps(result, indent=2), flush=True)


if __name__ == "__main__":
    main()
