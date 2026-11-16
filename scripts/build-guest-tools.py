#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build native ARM64 guest tools from explicitly supplied, pinned upstream ZIPs.

No download, host driver installation, guest execution or VM modification occurs.
Output is bounded to build/guest-tools. The source build does not require these
optional artifacts; a prebuilt distribution must supply its reviewed ISO pins.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VIRTIO_SHA = "b054af39278900da9def6163f3b9b13e615b73b18b0fce33b47f6d89c76fa008"
NEPTUNE_SHA = "512da8ef87eaf4f65282e2535bf1dc2b32b0b0f825508093532fbb1ab0b09116"
PACKAGES = [
    ("Network", "drivers/netkvm/netkvm.inf", "PCI\\VEN_1AF4&DEV_1000", "PCI\\VEN_1AF4&DEV_1041", "netkvm", False),
    ("Guest communication", "drivers/vioser/vioser.inf", "PCI\\VEN_1AF4&DEV_1003", "PCI\\VEN_1AF4&DEV_1043", "VirtioSerial", False),
]
IMPORTS = {
    "kernel32": "CloseHandle CompareStringOrdinal CreateDirectoryW CreateFileW CreateProcessW CreateThread ExitProcess FlushFileBuffers GetCommandLineW GetCurrentProcess GetEnvironmentVariableW GetExitCodeProcess GetFileAttributesW GetFileInformationByHandle GetLastError GetModuleFileNameW GetModuleHandleW GetSystemDirectoryW GetTempFileNameW LocalFree ReadFile WaitForSingleObject WriteFile lstrcatW lstrcmpW lstrcmpiW lstrcpyW lstrlenW",
    "user32": "CreateWindowExW DefWindowProcW DestroyWindow DispatchMessageW EnableWindow GetMessageW IsDialogMessageW LoadCursorW MessageBoxW PostMessageW PostQuitMessage RegisterClassW SendMessageW SetFocus SetWindowTextW ShowWindow TranslateMessage UpdateWindow wsprintfW",
    "gdi32": "CreateFontW DeleteObject",
    "advapi32": "GetTokenInformation OpenProcessToken RegCloseKey RegDeleteValueW RegOpenKeyExW RegQueryValueExW RegSetValueExW",
    "shell32": "CommandLineToArgvW ShellExecuteExW",
    "setupapi": "SetupDiDestroyDeviceInfoList SetupDiEnumDeviceInfo SetupDiGetClassDevsW SetupDiGetDeviceRegistryPropertyW",
    "cfgmgr32": "CM_Get_DevNode_Status",
    "bcrypt": "BCryptCloseAlgorithmProvider BCryptCreateHash BCryptDestroyHash BCryptFinishHash BCryptHashData BCryptOpenAlgorithmProvider",
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def archive(path, expected):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 16 << 20:
        raise ValueError("Invalid input archive")
    if sha(path.read_bytes()) != expected:
        raise ValueError("Upstream archive checksum mismatch")
    payload = {}
    with zipfile.ZipFile(path) as source:
        for entry in source.infolist():
            if entry.is_dir():
                continue
            name = entry.filename
            if (not re.fullmatch(r"[A-Za-z0-9_. /-]+", name)
                    or any(p in ("", ".", "..") for p in name.split("/"))
                    or PurePosixPath(name).is_absolute()
                    or name.casefold() in {p.casefold() for p in payload}
                    or entry.file_size > 16 << 20
                    or len(payload) >= 64
                    or (entry.external_attr >> 16) & 0o170000 == 0o120000):
                raise ValueError("Unsafe archive member")
            payload[name] = source.read(entry)
    if sum(map(len, payload.values())) > 24 << 20:
        raise ValueError("Archive payload too large")
    return payload


def cstring(value):
    return "L" + json.dumps(value.replace("/", "\\"))


def header(payload, packages):
    if len(payload) > 64:
        raise ValueError("Too many installer inputs")
    lines = ["// Generated from pinned archives; do not edit.",
             "static const struct { const WCHAR *path; DWORD size; unsigned char sha[32]; } payload[] = {"]
    for name, data in sorted(payload.items()):
        digest = ",".join("0x" + sha(data)[i:i+2] for i in range(0, 64, 2))
        lines.append("{%s,%d,{%s}}," % (cstring(name), len(data), digest))
    lines += ["};", "#define PAYLOAD_COUNT (sizeof(payload)/sizeof(payload[0]))",
              "static const struct { const WCHAR *name, *inf, *id1, *id2, *service; BOOL graphics, required; } packages[] = {"]
    for row in packages:
        # A graphics profile promises a GPU. Its absence is an incomplete setup,
        # never an optional-package skip (including the non-accelerated profile).
        required = row[4] in ("VioGpuDod", "VioGpu3D")
        lines.append("{" + ",".join(cstring(s) for s in row[:5]) + "," + str(int(row[5])) + "," + str(int(required)) + "},")
    return "\n".join(lines + ["};", "#define PACKAGE_COUNT (sizeof(packages)/sizeof(packages[0]))", ""])


def iso_files(data, normalize=False):
    """Read bounded generated ISO9660/Joliet; optionally normalize its timestamps."""
    data = bytearray(data)
    if len(data) % 2048 or not 20 * 2048 <= len(data) <= 32 << 20:
        raise ValueError("ISO size")
    found = None
    for sector in range(16, 32):
        at = sector * 2048
        if data[at+1:at+6] != b"CD001":
            raise ValueError("ISO descriptor")
        kind = data[at]
        if kind == 255:
            break
        if kind not in (1, 2):
            raise ValueError("ISO descriptor kind")
        joliet = kind == 2
        if joliet and data[at+88:at+91] not in (b"%/@", b"%/C", b"%/E"):
            raise ValueError("Missing Joliet names")
        if normalize:
            data[at+813:at+881] = (b"2000010100000000\x00" * 4)
        seen, members = set(), {}

        def normalize_system_use(start, end):
            # hdiutil includes Rock Ridge creation/access/change times and POSIX
            # owner IDs even with only -iso/-joliet. They are image metadata, not
            # payload; normalize them as well as the ISO directory timestamps.
            at = start
            while at + 4 <= end and data[at+2] >= 4:
                length = data[at+2]
                if at + length > end:
                    raise ValueError("ISO system-use record")
                tag = data[at:at+2]
                if tag == b"TF":
                    flags = data[at+4]
                    width = 17 if flags & 128 else 7
                    expected = 5 + (flags & 127).bit_count() * width
                    if length != expected:
                        raise ValueError("ISO timestamp record")
                    stamp = b"2000010100000000\x00" if width == 17 else bytes([100, 1, 1, 0, 0, 0, 0])
                    for offset in range(at+5, at+length, width):
                        data[offset:offset+width] = stamp
                elif tag == b"PX":
                    if length not in (36, 44):
                        raise ValueError("ISO POSIX record")
                    data[at+20:at+36] = bytes(16)
                at += length

        def walk(record_at, prefix="", depth=0):
            if depth > 5 or record_at + 34 > len(data):
                raise ValueError("ISO directory bound")
            if normalize:
                data[record_at+18:record_at+25] = bytes([100, 1, 1, 0, 0, 0, 0])
            start = int.from_bytes(data[record_at+2:record_at+6], "little") * 2048
            size = int.from_bytes(data[record_at+10:record_at+14], "little")
            if size > 65536 or start + size > len(data) or start in seen:
                raise ValueError("ISO directory extent")
            seen.add(start)
            offset = 0
            while offset < size:
                row = start + offset
                length = data[row]
                if not length:
                    offset = (offset // 2048 + 1) * 2048
                    continue
                if length < 34 or offset + length > size:
                    raise ValueError("ISO directory record")
                offset += length
                count = data[row+32]
                if count > length - 33 or data[row+25] & 128:
                    raise ValueError("ISO multi-extent or name")
                if normalize:
                    data[row+18:row+25] = bytes([100, 1, 1, 0, 0, 0, 0])
                    normalize_system_use(row+33+count+(1 if count % 2 == 0 else 0), row+length)
                raw = bytes(data[row+33:row+33+count])
                if raw in (b"\x00", b"\x01"):
                    continue
                name = raw.decode("utf-16-be" if joliet else "ascii").removesuffix(";1")
                if not name or name in (".", "..") or "/" in name or "\\" in name:
                    raise ValueError("ISO unsafe name")
                path = prefix + name
                if data[row+25] & 2:
                    walk(row, path + "/", depth+1)
                else:
                    first = int.from_bytes(data[row+2:row+6], "little") * 2048
                    size_file = int.from_bytes(data[row+10:row+14], "little")
                    if first + size_file > len(data) or len(members) >= 64 or path in members:
                        raise ValueError("ISO file extent")
                    members[path] = bytes(data[first:first+size_file])
        walk(at+156)
        if joliet:
            found = members
    if found is None:
        raise ValueError("Missing Joliet tree")
    return bytes(data), found


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def build(args):
    virtio = archive(args.virtio_zip, VIRTIO_SHA)
    neptune = archive(args.neptune_zip, NEPTUNE_SHA)
    output = ROOT / "build/guest-tools"
    output.mkdir(parents=True, exist_ok=True)
    source = ROOT / "GuestAgent/Windows/Tools/installer.c"
    records = {}
    with tempfile.TemporaryDirectory(prefix="guest-tools-", dir=output) as temporary:
        work = Path(temporary)
        libraries = []
        for dll, functions in IMPORTS.items():
            definition = work / (dll + ".def")
            definition.write_text("LIBRARY " + dll + ".dll\nEXPORTS\n" + "\n".join(functions.split()) + "\n")
            library = work / (dll + ".lib")
            run(args.llvm_bin / "llvm-dlltool", "-m", "arm64", "-d", definition, "-l", library)
            libraries.append(library)
        for profile in ("basic", "display", "accelerated"):
            stage = work / profile
            stage.mkdir()
            payload = {name: data for name, data in virtio.items()
                       if name.startswith(("drivers/netkvm/", "drivers/vioser/", "licenses/"))}
            packages = list(PACKAGES)
            if profile == "display":
                payload.update({name: data for name, data in virtio.items() if name.startswith("drivers/display/")})
                packages.append(("Graphics", "drivers/display/viogpudo.inf", "PCI\\VEN_1AF4&DEV_1050", "PCI\\VEN_1AF4&DEV_1050", "VioGpuDod", False))
            elif profile == "accelerated":
                for name, data in neptune.items():
                    payload["drivers/graphics/" + PurePosixPath(name).name] = data
                payload["drivers/graphics/virtio-win_license.txt"] = virtio["drivers/display/virtio-win_license.txt"]
                packages.append(("Accelerated graphics", "drivers/graphics/viogpu3d.inf", "PCI\\VEN_1AF4&DEV_1050", "PCI\\VEN_1AF4&DEV_1050", "VioGpu3D", True))
            payload["Driver sources.txt"] = ("VirtIO 0.1.302-1: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/\r\n"
                "Neptune v0.4 (accelerated profile only): https://github.com/osy/kvm-guest-drivers-windows/releases/tag/v0.4\r\n"
                "Installer source: https://github.com/alexanderisgood/macOpenVM/tree/main/GuestAgent/Windows/Tools\r\n").encode()
            (work / "payload.h").write_text(header(payload, packages))
            obj = work / "installer.obj"
            run(args.llvm_bin / "clang", "--target=aarch64-w64-windows-gnu", "--no-default-config", "-std=c11", "-O2",
                "-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-Wall", "-Wextra", "-Werror",
                "-D_WIN32_WINNT=0x0A00", "-isystem", args.headers, "-I", work, "-c", source, "-o", obj)
            exe = stage / "Install macOpenVM Tools.exe"
            run(args.linker, "-flavor", "link", "/machine:ARM64", "/subsystem:windows", "/entry:mvo_start",
                "/nodefaultlib", "/Brepro", "/dynamicbase", "/nxcompat", "/opt:ref", "/WX",
                "/manifest:embed", "/manifestuac:level='asInvoker' uiAccess='false'", obj, *libraries, "/out:" + str(exe))
            for name, data in payload.items():
                path = stage / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            (stage / "autorun.inf").write_text('[autorun]\r\nopen="Install macOpenVM Tools.exe"\r\naction=Install macOpenVM Guest Tools\r\nlabel=macOpenVM Guest Tools\r\n')
            (stage / "Read me.txt").write_text("Open Install macOpenVM Tools, choose Install, then approve Windows' administrator prompt.\r\n"
                "The installer checks every driver file, installs matching devices, and reports any restart needed.\r\n"
                "If Windows Setup asks for a network driver first, select drivers\\netkvm on this disc.\r\n"
                "This " + profile + " disc is paired with its macOpenVM runtime. Do not use it with other VM software.\r\n"
                "No Windows ISO, account, agent enrollment, or automatic restart is included.\r\n")
            (stage / "Installer LICENSE.txt").write_bytes((ROOT / "LICENSE").read_bytes())
            for path in sorted(stage.rglob("*"), reverse=True):
                os.utime(path, (946684800, 946684800))
            os.utime(stage, (946684800, 946684800))
            image = work / (profile + ".iso")
            run("/usr/bin/hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name", "MACOPENVM_TOOLS", "-o", image, stage)
            normalized, members = iso_files(image.read_bytes(), normalize=True)
            expected = {p.relative_to(stage).as_posix(): p.read_bytes() for p in stage.rglob("*") if p.is_file()}
            if members != expected or iso_files(normalized)[1] != expected:
                raise ValueError("Generated ISO readback mismatch")
            (output / (profile + ".iso")).write_bytes(normalized)
            records[profile] = {"bytes": len(normalized), "sha256": sha(normalized),
                "installerSHA256": sha(exe.read_bytes()), "files": {name: sha(data) for name, data in sorted(expected.items())}}
    (output / "manifest.json").write_text(json.dumps(records, indent=2, sort_keys=True) + "\n")
    print(json.dumps({name: {k: v for k, v in row.items() if k != "files"} for name, row in records.items()}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ("virtio-zip", "neptune-zip", "llvm-bin", "linker", "headers"):
        parser.add_argument("--" + argument, type=Path, required=True)
    build(parser.parse_args())
