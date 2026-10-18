#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Experimental static-only Windows ARM64 build lab. Never executes the produced PE."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "GuestAgent/Windows/native_build_lab.c"
HEADER = ROOT / "GuestAgent/Protocol/generated/agent_v1.h"
VECTORS = ROOT / "Tests/AgentProtocolTests/vectors.json"
LLVM = Path("/opt/homebrew/Cellar/llvm/22.1.8")
ZSTD_LOADER = Path("/opt/homebrew/Cellar/zstd/1.5.7_1/lib")
CLANG_PIN = "305697d3868243dca6e4aabf4f628df7de135d701eb4fd78f6a5d7528fef4395"
LLD_PIN = "7f629593760ab23657f57ad6b996b6d38c1ea922a5bcd02b4b27c3b5364d1f8c"
IMPORT_SYMBOLS = {
    "kernel32.dll": {"CloseHandle", "CreateEventW", "ExitProcess", "GetStdHandle", "ResetEvent",
                     "SetEvent", "WaitForSingleObject", "WriteFile"},
    "secur32.dll": {"FreeContextBuffer", "QuerySecurityPackageInfoW"},
    "crypt32.dll": {"CertCloseStore", "CertOpenStore"},
}


class BuildLabError(RuntimeError):
    pass


def require(condition, code):
    if not condition:
        raise BuildLabError(code)


def plain(path, directory=False):
    require(path.is_absolute() and str(path) == os.path.abspath(path), "absolute-normalized-path-required")
    for node in (path, *path.parents):
        info = node.lstat()
        require(not stat.S_ISLNK(info.st_mode), "symlink-input-rejected")
        if node != path:
            require(stat.S_ISDIR(info.st_mode), "non-directory-ancestor")
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode), "plain-input-required")
    return info


def digest(path, limit=256 << 20):
    before = plain(path)
    require(0 < before.st_size <= limit, "input-size-outside-bound")
    value = hashlib.sha256()
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(descriptor, "rb") as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "plain-input-required")
        while block := stream.read(65536):
            value.update(block)
        after = os.fstat(stream.fileno())
    require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
            "input-changed-while-hashing")
    return value.hexdigest()


def save(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)


def save_json(path, data):
    save(path, json.dumps(data, indent=2, sort_keys=True).encode() + b"\n")


def source_inputs():
    text = SOURCE.read_text()
    rows = json.loads(VECTORS.read_text())
    arrays = re.findall(r"static const unsigned char vector_([0-9]+)\[\] = \{([^}]+)\};", text)
    require(len(arrays) == len(rows) == 5, "retained-vector-count-changed")
    for index, ((number, elements), row) in enumerate(zip(arrays, rows)):
        tokens = [token.strip() for token in elements.split(",")]
        require(number == str(index) and all(re.fullmatch(r"0x[0-9a-fA-F]{2}", token) for token in tokens),
                "retained-vector-shape-changed")
        require(bytes(int(token, 16) for token in tokens).hex() == row["frameHex"], "retained-vector-bytes-changed")
    return [{"path": str(path), "sha256": digest(path, 1 << 20)} for path in (SOURCE, HEADER, VECTORS)]


def dependency_inputs(sysroot, imports):
    include = sysroot / "include"
    plain(include, directory=True)
    rows = []
    total = 0
    for path in sorted(include.rglob("*")):
        info = path.lstat()
        require(not stat.S_ISLNK(info.st_mode), "symlink-header-rejected")
        if stat.S_ISDIR(info.st_mode):
            continue
        require(stat.S_ISREG(info.st_mode), "plain-header-required")
        total += info.st_size
        require(len(rows) < 4096 and total <= 256 << 20, "header-tree-outside-bound")
        rows.append({"path": str(path), "bytes": info.st_size, "sha256": digest(path, 16 << 20)})
    for name in ("windows.h", "sspi.h", "schannel.h", "wincrypt.h", "winternl.h", "_mingw.h"):
        plain(include / name)
    for name in ("libkernel32.a", "libsecur32.a", "libcrypt32.a"):
        path = imports / name
        rows.append({"path": str(path), "bytes": plain(path).st_size, "sha256": digest(path, 4 << 20)})
    return rows


def inspect_pe(text):
    require("Format: COFF-ARM64" in text and "Machine: IMAGE_FILE_MACHINE_ARM64 (0xAA64)" in text,
            "unexpected-pe-machine")
    require("Magic: 0x20B" in text and "Subsystem: IMAGE_SUBSYSTEM_WINDOWS_CUI (0x3)" in text,
            "unexpected-pe-format-or-subsystem")
    entry = re.search(r"AddressOfEntryPoint: (0x[0-9A-Fa-f]+)", text)
    require(entry is not None and int(entry.group(1), 16) != 0, "missing-custom-entry")
    actual = {}
    for block in re.findall(r"Import \{([^}]+)\}", text):
        name = re.search(r"Name: ([^\n]+)", block)
        require(name is not None, "unnamed-import")
        dll = name.group(1).lower()
        require(dll not in actual, "duplicate-dll-import")
        actual[dll] = set(re.findall(r"Symbol: ([A-Za-z0-9_]+) \(", block))
    require(actual == IMPORT_SYMBOLS, "unexpected-native-import-closure")
    require(re.search(r"msvcrt|ucrt|vcruntime|libmingw|libgcc|libssp", text, re.IGNORECASE) is None,
            "crt-or-runtime-import-rejected")
    return {"machine": "ARM64-0xAA64", "format": "PE32+", "subsystem": "console",
            "entryRVA": entry.group(1), "imports": {name: sorted(symbols) for name, symbols in actual.items()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--sysroot", type=Path)
    parser.add_argument("--imports", type=Path)
    parser.add_argument("--lld", type=Path)
    args = parser.parse_args()
    if not args.run:
        print("SKIP: explicit --run required; no build or Windows execution performed.")
        return 0
    if args.sysroot is None or args.imports is None or args.lld is None:
        parser.error("--run requires --sysroot, --imports, and --lld")
    plain(args.sysroot, directory=True)
    plain(args.imports, directory=True)
    plain(args.lld)
    tools = {"clang": LLVM / "bin/clang-22", "lld": args.lld,
             "readobj": LLVM / "bin/llvm-readobj", "nm": LLVM / "bin/llvm-nm",
             "objdump": LLVM / "bin/llvm-objdump"}
    tool_rows = {name: {"path": str(path), "sha256": digest(path)} for name, path in tools.items()}
    require(tool_rows["clang"]["sha256"] == CLANG_PIN and tool_rows["lld"]["sha256"] == LLD_PIN,
            "qualified-22-tool-pin-changed")
    loaders = (args.lld.parent.parent / "lib", LLVM / "lib", ZSTD_LOADER)
    for path in loaders:
        plain(path, directory=True)
    for path in (SOURCE, HEADER, VECTORS):
        plain(path)
    sources = source_inputs()
    dependencies = dependency_inputs(args.sysroot, args.imports)
    plain(ROOT / ".lab", directory=True)
    fixture = ROOT / ".lab" / ("windows-native-build-lab-" + uuid.uuid4().hex)
    fixture.mkdir(mode=0o700)
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "DYLD_LIBRARY_PATH": ":".join(map(str, loaders))}
    operations = []

    def run(directory, label, argv, strict=False):
        out_path, err_path = directory / (label + ".stdout"), directory / (label + ".stderr")
        out = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        err = os.open(err_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(out, "wb") as stdout, os.fdopen(err, "wb") as stderr:
            process = subprocess.run(list(map(str, argv)), cwd=fixture, env=env, stdout=stdout,
                                     stderr=stderr, timeout=60, close_fds=True, check=False)
        row = {"label": label, "argv": list(map(str, argv)), "exit": process.returncode,
               "stdout": str(out_path), "stderr": str(err_path), "stderrBytes": err_path.stat().st_size}
        operations.append(row)
        save_json(directory / (label + ".json"), row)
        require(process.returncode == 0, "tool-operation-failed-" + label)
        require(not strict or err_path.stat().st_size == 0, "strict-diagnostic-" + label)
        require(out_path.stat().st_size <= 4 << 20 and err_path.stat().st_size <= 1 << 20,
                "diagnostic-output-outside-bound")
        return out_path.read_text()

    try:
        binaries = []
        for iteration in (1, 2):
            directory = fixture / ("build-" + str(iteration))
            directory.mkdir(mode=0o700)
            obj, binary = directory / "native_build_lab.obj", directory / "native_build_lab.exe"
            run(directory, "compile", [tools["clang"], "--target=aarch64-w64-windows-gnu", "--no-default-config",
                "-std=c11", "-O2", "-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-Wall", "-Wextra",
                "-Werror", "-Wpedantic", "-D_WIN32_WINNT=0x0A00", "-D_FORTIFY_SOURCE=0", "-isystem",
                args.sysroot / "include", "-I" + str(HEADER.parent), "-c", SOURCE, "-o", obj], strict=True)
            run(directory, "link", [args.lld, "-flavor", "link", "/machine:ARM64", "/subsystem:console",
                "/entry:mvo_start", "/nodefaultlib", "/Brepro", "/dynamicbase", "/nxcompat", "/opt:ref", "/WX", obj,
                args.imports / "libkernel32.a", args.imports / "libsecur32.a", args.imports / "libcrypt32.a",
                "/out:" + str(binary)], strict=True)
            inspection = run(directory, "inspect", [tools["readobj"], "--file-headers", "--coff-imports",
                                                     "--coff-load-config", binary])
            native = inspect_pe(inspection)
            run(directory, "object-undefined", [tools["nm"], "--undefined-only", obj])
            run(directory, "disassemble", [tools["objdump"], "--disassemble", binary])
            binary.chmod(0o500)
            binaries.append({"path": str(binary), "bytes": binary.stat().st_size, "sha256": digest(binary, 1 << 20),
                             "objectSHA256": digest(obj, 1 << 20), "inspection": native})
        require(binaries[0]["sha256"] == binaries[1]["sha256"], "binary-rebuild-differs")
        require(source_inputs() == sources and dependency_inputs(args.sysroot, args.imports) == dependencies,
                "build-input-changed")
        require(all(digest(path) == tool_rows[name]["sha256"] for name, path in tools.items()), "build-tool-changed")
        result = {"schemaVersion": 1, "status": "experimental-static-built-identically-not-executed",
                  "sourceInputs": sources, "dependencyInputs": dependencies, "toolInputs": tool_rows,
                  "runnerSHA256": digest(Path(__file__).resolve(), 1 << 20),
                  "loaderDirectories": list(map(str, loaders)), "operations": operations, "binaries": binaries,
                  "retainedGoldenVectorsMatched": 5, "identicalBinaryRebuild": True, "PEExecuted": False,
                  "runtimeQualified": False, "authenticatedHealthClaimed": False, "credentialsCreated": False,
                  "guestStarted": False, "networkOrDeviceOpened": False, "globalInstall": False,
                  "CRTorRuntimeLinked": False}
        save_json(fixture / "result.json", result)
        print(json.dumps({"fixture": str(fixture), "status": result["status"], "binarySHA256": binaries[0]["sha256"],
                          "binaryBytes": binaries[0]["bytes"], "identicalRebuild": True, "PEExecuted": False}))
        return 0
    except Exception as error:
        save_json(fixture / "failure.json", {"status": "failed-build-only", "failureType": type(error).__name__,
                                            "operations": operations, "PEExecuted": False})
        raise


if __name__ == "__main__":
    raise SystemExit(main())
