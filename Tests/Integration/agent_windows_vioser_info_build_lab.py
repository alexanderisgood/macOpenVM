#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Separate experimental ARM64 discovery/INFO static build; never executes its PE."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import uuid

from agent_windows_build_lab import ROOT, LLVM, ZSTD_LOADER, CLANG_PIN, LLD_PIN, plain, digest, require, save_json

SOURCE = ROOT / "GuestAgent/Windows/vioser_info_lab.c"
HEADER = ROOT / "GuestAgent/Windows/vioser_info_contract.h"
NATIVE_HEADER = ROOT / "GuestAgent/Windows/vioser_win32_lab.h"
TRANSFER_SOURCE = ROOT / "GuestAgent/Windows/vioser_transfer_lab.c"
TRANSFER_HEADER = ROOT / "GuestAgent/Windows/vioser_transfer_contract.h"
MINGW = ROOT / ".lab/windows-native-smoke-d677b66295564b7087dd303b65b7a1e4"
DRIVER = ROOT / ".lab/windows-vioser-source-150a26adefc54559bba05eacf3917af0"
DEFINITION = MINGW / "source/mingw-w64-v14.0.0/mingw-w64-crt/lib-common/setupapi.def"
DRIVER_PINS = {"public.h": "1719b2d0c1a5d1e885c565ad8a4fd114c8f63cad21eab5a7f8652f6b49a89201",
               "Port.c": "0dcad662e14e9d5d5ed43bf6f068e961afc08a018ce8002100571abca7f09c33"}
DLLTOOL_PIN = "59d03f99b04b7751f736127bf03bda69badface189a01617a45b1ad7b632fbca"
DLLS = {
    "kernel32.dll": {"CancelIoEx", "CloseHandle", "CreateEventW", "CreateFileW", "DeviceIoControl",
        "ExitProcess", "GetLastError", "GetOverlappedResult", "GetStdHandle", "GetTickCount64", "ResetEvent",
        "SetConsoleCtrlHandler", "SetEvent", "Sleep", "WaitForMultipleObjects", "WaitForSingleObject", "WriteFile"},
    "setupapi.dll": {"SetupDiDestroyDeviceInfoList", "SetupDiEnumDeviceInterfaces", "SetupDiGetClassDevsW",
                     "SetupDiGetDeviceInterfaceDetailW"},
}


def input_rows(transfer=False):
    paths = [TRANSFER_SOURCE if transfer else SOURCE, HEADER, NATIVE_HEADER, Path(__file__).resolve(), DEFINITION, MINGW / "imports/libkernel32.a", DRIVER / "qualification.json",
             DRIVER / "LICENSE", *(DRIVER / name for name in DRIVER_PINS)]
    if transfer:
        paths.append(TRANSFER_HEADER)
    for path in paths:
        plain(path)
    for name, pin in DRIVER_PINS.items():
        require(digest(DRIVER / name) == pin, "driver-public-source-pin")
    require(digest(DRIVER / "qualification.json") == "96b5b19cf2a557979e08500130536cf87f9d68138ffea3bc7e24ad6ea69e01eb", "driver-source-qualification-pin")
    require(digest(MINGW / "imports/libkernel32.a") == "e74d211111d39132846bd7b2dd943fd7795f96cff34fcc23e9226df0d5a6d63d", "kernel32-pin")
    total = 0
    header_count = 0
    for path in sorted((MINGW / "prefix/include").rglob("*")):
        if path.is_dir():
            plain(path, directory=True)
        else:
            plain(path)
            total += path.stat().st_size
            header_count += 1
            require(header_count <= 4096 and total <= 256 << 20 and path.stat().st_size <= 16 << 20,
                    "bounded-header-tree-required")
            paths.append(path)
    require(len(paths) < 4096, "bounded-input-count")
    return [{"path": str(p), "bytes": p.stat().st_size, "sha256": digest(p)} for p in paths]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Build only; never run the resulting Windows program")
    parser.add_argument("--transfer", action="store_true", help="Build the fixed read-first transfer evaluator instead of INFO only")
    parser.add_argument("--lld", type=Path, required=False)
    args = parser.parse_args()
    if not args.run:
        print("SKIP: explicit static build required; no PE/device/guest operation")
        return 0
    require(args.lld is not None, "explicit-private-linker-required")
    dlltool_alias = LLVM / "bin/llvm-dlltool"
    dlltool_binary = dlltool_alias.resolve()
    require(dlltool_alias.is_symlink() and dlltool_binary == LLVM / "bin/llvm-ar", "known-dlltool-alias-required")
    require(digest(dlltool_binary) == DLLTOOL_PIN, "qualified-dlltool-pin-required")
    tools = {"clang": LLVM / "bin/clang-22", "dlltool": dlltool_binary,
             "readobj": LLVM / "bin/llvm-readobj", "nm": LLVM / "bin/llvm-nm", "lld": args.lld}
    for path in tools.values():
        plain(path)
    require(digest(tools["clang"]) == CLANG_PIN and digest(tools["lld"]) == LLD_PIN, "qualified-tool-pins")
    loaders = [args.lld.parent.parent / "lib", LLVM / "lib", ZSTD_LOADER]
    for path in loaders:
        plain(path, directory=True)
    inputs = input_rows(args.transfer)
    os.umask(0o077)
    fixture = ROOT / ".lab" / (("windows-vioser-transfer-build-" if args.transfer else "windows-vioser-info-build-") + uuid.uuid4().hex)
    fixture.mkdir(mode=0o700)
    # LLVM selects dlltool mode by argv[0]. Copy its pinned multicall binary under
    # the correct private name; do not follow arbitrary caller-supplied aliases.
    private_dlltool = fixture / "llvm-dlltool"
    shutil.copyfile(dlltool_binary, private_dlltool)
    private_dlltool.chmod(0o500)
    require(digest(private_dlltool) == digest(dlltool_binary), "private-dlltool-copy-required")
    tools["dlltool"] = private_dlltool
    tool_inputs = {name:{"path":str(path),"sha256":digest(path)} for name,path in tools.items()}
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "DYLD_LIBRARY_PATH": ":".join(map(str, loaders))}
    operations = []
    def run(label, argv, strict=True):
        out, err = fixture / (label + ".stdout"), fixture / (label + ".stderr")
        with out.open("xb") as stdout, err.open("xb") as stderr:
            child = subprocess.run(list(map(str, argv)), cwd=fixture, env=env, stdin=subprocess.DEVNULL,
                                   stdout=stdout, stderr=stderr, timeout=60, check=False)
        operations.append({"label": label, "argv": list(map(str, argv)), "exit": child.returncode,
                           "stderrBytes": err.stat().st_size})
        require(child.returncode == 0 and (not strict or err.stat().st_size == 0), "strict-build-operation-" + label)
        require(out.stat().st_size <= 4 << 20 and err.stat().st_size <= 1 << 20, "bounded-diagnostics")
        return out.read_text()
    try:
        setup = fixture / "libsetupapi.a"
        run("setup-import", [tools["dlltool"], "-m", "arm64", "-d", DEFINITION, "-l", setup])
        binaries = []
        import re
        for iteration in (1, 2):
            obj, binary = fixture / ("info-" + str(iteration) + ".obj"), fixture / ("info-" + str(iteration) + ".exe")
            run("compile-" + str(iteration), [tools["clang"], "--target=aarch64-w64-windows-gnu", "--no-default-config",
                "-std=c11", "-O2", "-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-Wall", "-Wextra",
                "-Werror", "-Wpedantic", "-Wconversion", "-Wsign-conversion", "-D_WIN32_WINNT=0x0A00", "-D_FORTIFY_SOURCE=0", "-isystem",
                MINGW / "prefix/include", "-c", TRANSFER_SOURCE if args.transfer else SOURCE, "-o", obj])
            run("link-" + str(iteration), [tools["lld"], "-flavor", "link", "/machine:ARM64", "/subsystem:console",
                "/entry:mvo_start", "/nodefaultlib", "/Brepro", "/dynamicbase", "/nxcompat", "/opt:ref", "/WX",
                obj, MINGW / "imports/libkernel32.a", setup, "/out:" + str(binary)])
            report = run("inspect-" + str(iteration), [tools["readobj"], "--file-headers", "--coff-imports", binary])
            require("Format: COFF-ARM64" in report and "Machine: IMAGE_FILE_MACHINE_ARM64 (0xAA64)" in report
                    and "Magic: 0x20B" in report and "Subsystem: IMAGE_SUBSYSTEM_WINDOWS_CUI (0x3)" in report,
                    "ARM64-console-PE-required")
            entry = re.search(r"AddressOfEntryPoint: (0x[0-9A-Fa-f]+)", report)
            require(entry is not None and int(entry.group(1), 16) != 0, "custom-nonzero-entry-required")
            actual = {}
            for block in re.findall(r"Import \{([^}]+)\}", report):
                name = re.search(r"Name: ([^\n]+)", block).group(1).lower()
                require(name not in actual, "duplicate-import-library")
                actual[name] = set(re.findall(r"Symbol: ([A-Za-z0-9_]+) \(", block))
            expected_dlls = {name: set(symbols) for name, symbols in DLLS.items()}
            if args.transfer:
                expected_dlls["kernel32.dll"].add("ReadFile")
            require(actual == expected_dlls and not re.search(r"msvcrt|ucrt|vcruntime|libmingw|libgcc|libssp", report, re.I),
                    "exact-native-import-closure-required")
            undefined = run("undefined-" + str(iteration), [tools["nm"], "--undefined-only", obj])
            require("chkstk" not in undefined and "security_cookie" not in undefined, "no-runtime-helper-required")
            binary.chmod(0o500)
            binaries.append({"path": str(binary), "bytes": binary.stat().st_size, "sha256": digest(binary),
                             "objectSHA256": digest(obj), "imports": {k: sorted(v) for k,v in actual.items()}})
        require(binaries[0]["sha256"] == binaries[1]["sha256"], "deterministic-binary-rebuild-required")
        require(input_rows(args.transfer) == inputs, "input-preservation-required")
        require(all(digest(path) == tool_inputs[name]["sha256"] for name,path in tools.items()), "tool-preservation-required")
        save_json(fixture / "result.json", {"scope": "experimental-static-vioser-transfer-build-only" if args.transfer else "experimental-static-vioser-info-build-only", "status": "passed",
            "sourcesAndHeaders": inputs, "tools": tool_inputs,
            "runnerSHA256": digest(Path(__file__).resolve()),
            "setupImportSHA256": digest(setup), "operations": operations, "binaries": binaries,
            "PEExecuted": False, "deviceOpened": False, "driverInstalled": False, "guestStarted": False,
            "rawPortReadWritePerformed": False, "TLSServiceOrHealthClaimed": False,
            "consolePolicy": "CTRL_C/BREAK cooperative request only; CLOSE/logoff/OSshutdown may externally terminate",
            "cleanupDeadlineGuaranteed": False, "synchronousSetupAPIDeadlineGuaranteed": False,
            "driverBinarySourceBuildAssociationVerified": False})
        print(json.dumps({"fixture":str(fixture),"binarySHA256":binaries[0]["sha256"],"bytes":binaries[0]["bytes"],
                          "twoIdenticalBuilds":True,"PEExecuted":False}),flush=True)
        return 0
    except Exception as error:
        save_json(fixture / "failure.json", {"scope":"static-build-only","failureType":type(error).__name__,
                                            "operations":operations,"PEExecuted":False})
        raise


if __name__ == "__main__":
    raise SystemExit(main())
