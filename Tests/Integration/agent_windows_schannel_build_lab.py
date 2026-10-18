#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Experimental deterministic Schannel ARM64 build; never executes its PE."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import uuid

from agent_windows_build_lab import (
    ROOT, LLVM, ZSTD_LOADER, CLANG_PIN, LLD_PIN, plain, digest, require, save_json,
)

SOURCE = ROOT / "GuestAgent/Windows/schannel_credential_lab.c"
HEADER = ROOT / "GuestAgent/Windows/schannel_token_contract.h"
RECORD_HEADER = ROOT / "GuestAgent/Windows/schannel_record_contract.h"
MINGW = ROOT / ".lab/windows-native-smoke-d677b66295564b7087dd303b65b7a1e4"
MINGW_SOURCE = MINGW / "source/mingw-w64-v14.0.0"
MANIFEST_PINS = {
    "acquisition.json": "fd90a5dd6ff3cbf07071abbf826bb7fda11516dedd45992dd7fa4c7332371b5e",
    "licenses.json": "19595d8214de436ccec2f546aaaae5871a363ca68081157faf78078780bf8b96",
    "dependency-inputs.json": "f4eb531409437f1868ae0d5a36c8ec31db5145631abbb1b5b8e74fd2cb0fccc3",
}
ARCHIVE_PIN = "6eaf921d9eb987d3820b364ea9775bc19b965ec81490b6fdd716526c28e1995c"
TOOL_PINS = {
    "clang": CLANG_PIN,
    "lld": LLD_PIN,
    "dlltool": "59d03f99b04b7751f736127bf03bda69badface189a01617a45b1ad7b632fbca",
    "readobj": "32ff6e5810ed71aef4c679613a81786e7e7bc616035f8bd36fcee2164802a470",
    "nm": "98877e5da3a0591c4abeaf1819ca81976e886ec17550b10f81b0f5569890d5b5",
}
IMPORTS = {
    "kernel32.dll": {
        "GetCommandLineW", "CreateFileW", "GetFileType", "GetFileInformationByHandle",
        "GetFileSizeEx", "ReadFile", "CloseHandle", "GetLastError", "GetStdHandle",
        "WriteFile", "ExitProcess", "GetTickCount64",
    },
    "secur32.dll": {
        "FreeContextBuffer", "AcquireCredentialsHandleW",
        "FreeCredentialsHandle", "InitializeSecurityContextW", "AcceptSecurityContext",
        "DeleteSecurityContext", "QueryContextAttributesW",
        "EncryptMessage", "DecryptMessage",
    },
    "crypt32.dll": {
        "PFXImportCertStore", "CertEnumCertificatesInStore", "CertDuplicateCertificateContext",
        "CertFreeCertificateContext", "CertCloseStore", "CertGetCertificateContextProperty",
        "CertFindExtension", "CryptDecodeObjectEx", "CertOpenStore",
        "CertAddCertificateContextToStore", "CertCreateCertificateChainEngine",
        "CertFreeCertificateChainEngine", "CertGetCertificateChain",
        "CertVerifyCertificateChainPolicy", "CertFreeCertificateChain",
    },
}


def input_rows():
    """Qualify installed headers/import definitions against prior pinned acquisition."""
    paths = [SOURCE, HEADER, RECORD_HEADER, Path(__file__).resolve(),
             ROOT / "Tests/Integration/agent_windows_build_lab.py"]
    for name, pin in MANIFEST_PINS.items():
        path = MINGW / name
        require(digest(path, 1 << 20) == pin, "qualified-manifest-pin-" + name)
        paths.append(path)
    archive = MINGW / "mingw-w64-v14.0.0.tar.bz2"
    require(digest(archive, 16 << 20) == ARCHIVE_PIN, "qualified-mingw-archive-pin")
    paths.append(archive)
    manifest = json.loads((MINGW / "dependency-inputs.json").read_text())
    require(manifest["archiveSHA256"] == ARCHIVE_PIN and manifest["noticesCopiedToPrivatePrefix"] is True,
            "qualified-dependency-manifest-required")
    rows = manifest["inputs"]
    require(isinstance(rows, list) and 0 < len(rows) < 4096, "bounded-dependency-input-count")
    total = 0
    expected_headers = set()
    for row in rows:
        relative = Path(row["path"])
        require(not relative.is_absolute() and ".." not in relative.parts, "relative-manifest-path-required")
        path = MINGW / relative
        info = plain(path)
        total += info.st_size
        require(total <= 256 << 20 and info.st_size == row["bytes"] and info.st_size <= 16 << 20,
                "bounded-qualified-dependency-required")
        require(digest(path, 16 << 20) == row["sha256"], "qualified-dependency-pin")
        paths.append(path)
        if row["kind"] == "installed-header":
            expected_headers.add(path)
    actual_headers = set()
    for path in (MINGW / "prefix/include").rglob("*"):
        if path.is_dir():
            plain(path, directory=True)
        else:
            plain(path)
            actual_headers.add(path)
    require(actual_headers == expected_headers, "exact-qualified-header-tree-required")
    licenses = json.loads((MINGW / "licenses.json").read_text())
    require(licenses["sourceArchiveSHA256"] == ARCHIVE_PIN, "qualified-license-source-required")
    for row in licenses["notices"]:
        relative = Path(row["path"])
        require(not relative.is_absolute() and ".." not in relative.parts, "relative-license-path-required")
        path = MINGW_SOURCE / relative
        require(plain(path).st_size == row["bytes"] and digest(path, 1 << 20) == row["sha256"],
                "qualified-license-pin")
        paths.append(path)
    for name in ("windows.h", "winternl.h", "sspi.h", "schannel.h", "wincrypt.h"):
        require(MINGW / "prefix/include" / name in expected_headers, "required-native-header-qualified")
    require(len(paths) < 4096, "bounded-build-input-count")
    return [{"path": str(path), "bytes": plain(path).st_size, "sha256": digest(path)} for path in paths]


def inspect_pe(report):
    require("Format: COFF-ARM64" in report and "Machine: IMAGE_FILE_MACHINE_ARM64 (0xAA64)" in report
            and "Magic: 0x20B" in report and "Subsystem: IMAGE_SUBSYSTEM_WINDOWS_CUI (0x3)" in report,
            "ARM64-console-PE-required")
    entry = re.search(r"AddressOfEntryPoint: (0x[0-9A-Fa-f]+)", report)
    require(entry is not None and int(entry.group(1), 16) != 0, "custom-nonzero-entry-required")
    for characteristic in ("DYNAMIC_BASE", "HIGH_ENTROPY_VA", "NX_COMPAT"):
        require("IMAGE_DLL_CHARACTERISTICS_" + characteristic in report, "PE-mitigation-" + characteristic)
    actual = {}
    for block in re.findall(r"Import \{([^}]+)\}", report):
        match = re.search(r"Name: ([^\n]+)", block)
        require(match is not None, "named-import-required")
        name = match.group(1).lower()
        require(name not in actual, "duplicate-import-library")
        actual[name] = set(re.findall(r"Symbol: ([A-Za-z0-9_]+) \(", block))
    require(actual == IMPORTS, "exact-native-import-closure-required")
    require(not re.search(r"msvcrt|ucrt|vcruntime|libmingw|libgcc|libssp|ws2_32|setupapi", report, re.I),
            "no-CRT-socket-or-discovery-imports-required")
    return {"entryRVA": entry.group(1), "dynamicBase": True, "highEntropyVA": True, "nxCompatible": True,
            "imports": {name: sorted(symbols) for name, symbols in actual.items()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Build only; never execute Windows code")
    parser.add_argument("--lld", type=Path)
    args = parser.parse_args()
    if not args.run:
        print("SKIP: explicit static build required; no Windows execution or credential operations")
        return 0
    require(args.lld is not None, "explicit-private-linker-required")
    alias = LLVM / "bin/llvm-dlltool"
    dlltool = alias.resolve()
    require(alias.is_symlink() and dlltool == LLVM / "bin/llvm-ar", "known-dlltool-alias-required")
    tools = {"clang": LLVM / "bin/clang-22", "lld": args.lld, "dlltool": dlltool,
             "readobj": LLVM / "bin/llvm-readobj", "nm": LLVM / "bin/llvm-nm"}
    for name, path in tools.items():
        require(digest(path) == TOOL_PINS[name], "qualified-tool-pin-" + name)
    original_tools = dict(tools)
    original_tool_rows = {name: {"path": str(path), "sha256": digest(path)}
                          for name, path in original_tools.items()}
    loaders = [args.lld.parent.parent / "lib", LLVM / "lib", ZSTD_LOADER]
    for path in loaders:
        plain(path, directory=True)
    inputs = input_rows()
    plain(ROOT / ".lab", directory=True)
    os.umask(0o077)
    fixture = ROOT / ".lab" / ("windows-schannel-build-" + uuid.uuid4().hex)
    fixture.mkdir(mode=0o700)
    private_dlltool = fixture / "llvm-dlltool"
    shutil.copyfile(dlltool, private_dlltool)
    private_dlltool.chmod(0o500)
    require(digest(private_dlltool) == TOOL_PINS["dlltool"], "private-dlltool-copy-required")
    tools["dlltool"] = private_dlltool
    tool_rows = {name: {"path": str(path), "sha256": digest(path)} for name, path in tools.items()}
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "DYLD_LIBRARY_PATH": ":".join(map(str, loaders))}
    operations = []
    print(json.dumps({"fixture": str(fixture), "scope": "static-build-only"}), flush=True)
    save_json(fixture / "admission.json", {"sourcesAndDependencies": inputs, "tools": tool_rows,
              "originalTools": original_tool_rows, "loaderDirectories": list(map(str, loaders)),
              "buildEnvironment": env, "PEExecuted": False})

    def run(label, argv):
        out, err = fixture / (label + ".stdout"), fixture / (label + ".stderr")
        with out.open("xb") as stdout, err.open("xb") as stderr:
            process = subprocess.run(list(map(str, argv)), cwd=fixture, env=env, stdin=subprocess.DEVNULL,
                                     stdout=stdout, stderr=stderr, timeout=60, close_fds=True, check=False)
        row = {"label": label, "argv": list(map(str, argv)), "exit": process.returncode,
               "stdout": str(out), "stderr": str(err), "stderrBytes": err.stat().st_size}
        operations.append(row)
        save_json(fixture / (label + ".json"), row)
        require(process.returncode == 0 and err.stat().st_size == 0, "strict-build-operation-" + label)
        require(out.stat().st_size <= 4 << 20 and err.stat().st_size <= 1 << 20, "bounded-diagnostics")
        return out.read_text()

    try:
        libraries = []
        for name in ("kernel32", "secur32", "crypt32"):
            library = fixture / ("lib" + name + ".a")
            run(name + "-import", [tools["dlltool"], "-m", "arm64", "-d",
                                  MINGW / "imports" / (name + ".def"), "-l", library])
            libraries.append(library)
        library_rows = [{"path": str(path), "sha256": digest(path)} for path in libraries]
        binaries = []
        for iteration in (1, 2):
            suffix = str(iteration)
            obj, binary = fixture / ("schannel-" + suffix + ".obj"), fixture / ("schannel-" + suffix + ".exe")
            run("compile-" + suffix, [tools["clang"], "--target=aarch64-w64-windows-gnu", "--no-default-config",
                "-std=c11", "-O2", "-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-Wall", "-Wextra",
                "-Werror", "-Wpedantic", "-Wconversion", "-Wsign-conversion", "-D_WIN32_WINNT=0x0A00",
                "-D_FORTIFY_SOURCE=0", "-isystem", MINGW / "prefix/include", "-c", SOURCE, "-o", obj])
            run("link-" + suffix, [tools["lld"], "-flavor", "link", "/machine:ARM64", "/subsystem:console",
                "/entry:mvo_start", "/nodefaultlib", "/Brepro", "/dynamicbase", "/nxcompat", "/opt:ref", "/WX",
                obj, *libraries, "/out:" + str(binary)])
            report = run("inspect-" + suffix, [tools["readobj"], "--file-headers", "--coff-imports",
                                              "--coff-load-config", binary])
            native = inspect_pe(report)
            undefined = run("undefined-" + suffix, [tools["nm"], "--undefined-only", obj])
            symbols = set()
            for line in undefined.splitlines():
                match = re.fullmatch(r"\s*U\s+(\S+)\s*", line)
                require(match is not None, "known-undefined-symbol-report-required")
                symbols.add(match.group(1))
            expected = {"__imp_" + symbol for group in IMPORTS.values() for symbol in group}
            # These pinned MinGW SSPI declarations lack dllimport. Their exact
            # native import thunks remain restricted to Secur32.dll in the PE.
            for symbol in ("FreeContextBuffer", "EncryptMessage", "DecryptMessage"):
                expected.remove("__imp_" + symbol)
                expected.add(symbol)
            require(symbols == expected, "exact-undefined-native-imports-required")
            binary.chmod(0o500)
            binaries.append({"path": str(binary), "bytes": binary.stat().st_size,
                             "sha256": digest(binary, 1 << 20), "objectSHA256": digest(obj, 1 << 20),
                             "inspection": native})
        require(binaries[0]["sha256"] == binaries[1]["sha256"], "deterministic-binary-rebuild-required")
        require(input_rows() == inputs, "input-preservation-required")
        require(all(digest(path) == row["sha256"] for path, row in zip(libraries, library_rows)),
                "generated-import-library-preservation-required")
        require(all(digest(path) == tool_rows[name]["sha256"] for name, path in tools.items()),
                "tool-preservation-required")
        require(all(digest(path) == original_tool_rows[name]["sha256"]
                    for name, path in original_tools.items()), "original-tool-preservation-required")
        require(alias.is_symlink() and alias.resolve() == dlltool, "dlltool-alias-preservation-required")
        result = {"schemaVersion": 1, "scope": "experimental-schannel-static-build-only", "status": "passed",
                  "sourcesAndDependencies": inputs, "tools": tool_rows, "originalTools": original_tool_rows,
                  "dlltoolAlias": {"path": str(alias), "target": str(dlltool)},
                  "loaderDirectories": list(map(str, loaders)), "buildEnvironment": env,
                  "operations": operations,
                  "importLibraries": library_rows,
                  "importLibrariesGeneratedOnceAndReused": True,
                  "binaries": binaries, "twoIdenticalBuilds": True, "PEExecuted": False,
                  "credentialsCreated": False, "certificateOrKeyOpened": False, "guestStarted": False,
                  "deviceOrNetworkOpened": False, "TLSHandshakeObserved": False,
                  "authenticatedHealthClaimed": False, "CRTorRuntimeLinked": False}
        save_json(fixture / "result.json", result)
        print(json.dumps({"fixture": str(fixture), "binarySHA256": binaries[0]["sha256"],
                          "bytes": binaries[0]["bytes"], "twoIdenticalBuilds": True, "PEExecuted": False}), flush=True)
        return 0
    except Exception as error:
        save_json(fixture / "failure.json", {"scope": "static-build-only", "failureType": type(error).__name__,
                                            "sourcesAndDependencies": inputs, "tools": tool_rows,
                                            "operations": operations, "PEExecuted": False})
        raise


if __name__ == "__main__":
    raise SystemExit(main())
