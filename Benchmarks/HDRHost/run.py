#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite generated HDR host qualification. Never selects an app/VM endpoint.

Build the actual production Qemu/SharedFrameWire targets first. This runner links
those real objects; it does not compile substitute backend implementations.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import threading
import time

REPO = Path(__file__).resolve().parents[2]
BENCH = Path(__file__).resolve().parent
TARGET = "arm64-apple-macosx14.0"
LIMIT = 8 * 1024 * 1024


def require(value, message):
    if not value:
        raise RuntimeError(message)


def pin(p):
    b = p.read_bytes()
    return {"path": str(p), "bytes": len(b), "sha256": hashlib.sha256(b).hexdigest()}


def write(p, value):
    with p.open("x") as output:
        json.dump(value, output, indent=2)
        output.write("\n")
    p.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("build-directory", "sdk", "clang", "swiftc", "output-directory"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    require(os.uname().sysname == "Darwin" and os.uname().machine == "arm64", "Apple Silicon macOS required")
    build, sdk = [p.resolve(strict=True) for p in (args.build_directory, args.sdk)]
    # Driver behavior depends on argv[0] (swiftc may link to swift-frontend).
    # Preserve the requested invocation spelling while pinning its target too.
    clang, swift = [p.absolute() for p in (args.clang, args.swiftc)]
    require(clang.is_file() and swift.is_file(), "Compiler invocation path missing")
    run = args.output_directory.absolute()
    run.mkdir(mode=0o700, exist_ok=False)
    sources, frozen, logs, tmp = [run / n for n in ("sources", "actual-build", "logs", "tmp")]
    for p in (sources, frozen, logs, tmp, run / "swift-cache", run / "clang-cache"):
        p.mkdir(mode=0o700)
    before, copies, outputs, results = [], [], [], []
    summary = {"scope": "generated FD/Metal offscreen copies and unsafe-slot rejection only",
               "WindowsHDRQualified": False, "FPSQualified": False, "success": False,
               "pairs": [], "errors": []}

    def freeze(src, dst):
        require(src.is_file() and not src.is_symlink(), "Not a regular immutable input: " + str(src))
        record = pin(src)
        dst.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        dst.chmod(0o400)
        copied = pin(dst)
        require(record["sha256"] == copied["sha256"], "Copy mismatch")
        before.append(record)
        copies.append({"source": record, "frozen": copied})

    env = {"PATH": str(clang.parent) + ":/usr/bin:/bin:/usr/sbin:/sbin",
           "HOME": os.environ["HOME"], "LANG": "C", "LC_ALL": "C", "TMPDIR": str(tmp),
           "SDKROOT": str(sdk), "MACOSX_DEPLOYMENT_TARGET": "14.0"}

    def owned(label, argv, seconds, observe=None):
        started = time.monotonic()
        record = {"argv": argv, "deadlineSeconds": seconds, "signals": [], "errors": [],
                  "actualParentRetained": False, "actualParentReaped": False,
                  "stdoutEOF": False, "stderrEOF": False, "observedBytes": {}, "retainedBytes": {}}
        lock, over_limit = threading.Lock(), threading.Event()
        child = None
        readers = []
        try:
            child = subprocess.Popen(argv, cwd=REPO, env=env, stdin=subprocess.DEVNULL,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            record.update(actualParentRetained=True, diagnosticPID=child.pid)

            def reader(name, stream):
                seen = kept = 0
                try:
                    log = logs / (label + "." + name)
                    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    with os.fdopen(fd, "wb") as output:
                        while True:
                            b = os.read(stream.fileno(), 65536)
                            if not b:
                                record[name + "EOF"] = True
                                break
                            seen += len(b)
                            take = b[:max(0, LIMIT - kept)]
                            output.write(take)
                            kept += len(take)
                            if seen > LIMIT:
                                over_limit.set()
                            if observe and name == "stdout" and seen <= LIMIT:
                                observe(b)
                except BaseException as error:
                    with lock:
                        record["errors"].append(name + ": " + repr(error))
                    over_limit.set()
                finally:
                    record["observedBytes"][name] = seen
                    record["retainedBytes"][name] = kept
                    stream.close()
            for name, stream in (("stdout", child.stdout), ("stderr", child.stderr)):
                t = threading.Thread(target=reader, args=(name, stream), daemon=True)
                readers.append(t)
                t.start()
            terminated = None
            while child.poll() is None:
                now = time.monotonic()
                if terminated is None and (now - started >= seconds or over_limit.is_set()):
                    child.terminate()  # Exact retained direct child, never PID discovery.
                    record["signals"].append("SIGTERM")
                    terminated = now
                elif terminated is not None and now - terminated >= 3:
                    child.kill()
                    record["signals"].append("SIGKILL")
                    terminated = float("inf")
                time.sleep(0.02)
            record["actualExit"] = child.wait()
            record["actualParentReaped"] = True
        except BaseException as error:
            record["errors"].append(repr(error))
            if child is not None and child.poll() is None:
                child.terminate()
                record["signals"].append("SIGTERM")
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    record["signals"].append("SIGKILL")
                    child.wait()
                record["actualExit"] = child.returncode
                record["actualParentReaped"] = True
        finally:
            for t in readers:
                t.join(timeout=5)
            record["readersJoined"] = all(not t.is_alive() for t in readers)
            record["seconds"] = time.monotonic() - started
            record["success"] = (record.get("actualExit") == 0 and record["actualParentReaped"]
                and record["stdoutEOF"] and record["stderrEOF"] and record["readersJoined"]
                and not record["signals"] and not record["errors"] and not over_limit.is_set())
            write(logs / (label + ".process.json"), record)
        return record

    try:
        for relative in ("App/HDRFrameMetalRenderer.swift", "App/HDRDrawableRetryBudget.swift",
                         "App/HDRPresentationCallbackGate.swift",
                         "App/HDRMetalPresentationProfile.swift",
                         "Backends/Qemu/HDRFrameClient.swift", "Backends/Qemu/HDRFrameConsumerState.swift",
                         "Backends/SharedFrameWire/SharedHDRFrameTransport.c",
                         "Backends/SharedFrameWire/SharedHDRFrameWire.c", "Backends/SharedFrameWire/SharedFrameWire.c"):
            freeze(REPO / relative, sources / relative)
        include = sources / "Backends/SharedFrameWire/include"
        for original in sorted((REPO / "Backends/SharedFrameWire/include").iterdir()):
            if original.suffix == ".h" or original.name == "module.modulemap":
                freeze(original, include / original.name)
        for name in ("fd-producer-fixture.c", "HDRHostMetalBench.swift"):
            freeze(BENCH / name, sources / name)
        objects = ["Qemu.o", "BackendAPI.o", "VMStorage.o", "SharedFrameWire.o"]
        for name in objects:
            freeze(build / name, frozen / name)
        for module in ("Qemu", "BackendAPI", "VMStorage"):
            directory = build / (module + ".swiftmodule")
            require(directory.is_dir() and not directory.is_symlink(), "Missing real module: " + module)
            for original in sorted(directory.rglob("*")):
                if original.is_file():
                    freeze(original, frozen / original.relative_to(build))
        before += [pin(path) for path in dict.fromkeys(
            (clang, clang.resolve(strict=True), swift, swift.resolve(strict=True), Path(__file__).resolve()))]
        write(run / "input-pins-before.json", before)
        write(run / "frozen-copies.json", copies)
        write(run / "environment.json", env)
        require(all(pin(Path(record["path"])) == record for record in before),
                "Input changed while freezing")
        producer, consumer = run / "fd-producer-fixture", run / "hdr-host-metal-bench"
        commands = [
            ("producer-compile", [str(clang), "-target", TARGET, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                "-isysroot", str(sdk), "-I", str(include), str(sources / "fd-producer-fixture.c"),
                str(frozen / "SharedFrameWire.o"), "-lproc", "-o", str(producer)]),
            ("consumer-compile", [str(swift), "-target", TARGET, "-parse-as-library", "-swift-version", "6",
                "-warnings-as-errors", "-strict-concurrency=complete", "-sdk", str(sdk),
                "-module-cache-path", str(run / "swift-cache"), "-I", str(frozen), "-Xcc",
                "-fmodules-cache-path=" + str(run / "clang-cache"), "-Xcc", "-fmodule-map-file=" + str(include / "module.modulemap"),
                "-Xcc", "-I" + str(include), str(sources / "App/HDRMetalPresentationProfile.swift"),
                str(sources / "App/HDRDrawableRetryBudget.swift"),
                str(sources / "App/HDRPresentationCallbackGate.swift"),
                str(sources / "App/HDRFrameMetalRenderer.swift"), str(sources / "HDRHostMetalBench.swift"),
                *[str(frozen / n) for n in objects], "-lproc", "-o", str(consumer)]),
        ]
        write(run / "compile-steps.json", commands)
        for label, argv in commands:
            result = owned(label, argv, 180)
            results.append(result)
            require(result["success"], label + " failed")
        outputs = [pin(producer), pin(consumer)]
        write(run / "output-pins.json", outputs)
        for label, flag in (("positive", None), ("duplicate", "--duplicate-slots"), ("linked", "--linked-slots")):
            endpoint = Path(tempfile.mkdtemp(prefix="mvh-", dir="/private/tmp"))
            endpoint.chmod(0o700)
            parent = endpoint.lstat()
            sock = endpoint / "surface-hdr.sock"
            require(len(os.fsencode(sock)) <= 103, "Generated socket pathname too long")
            ready, finished = threading.Event(), threading.Event()
            pair, observed = {}, bytearray()
            expected = ("READY generated-hdr-socket " + str(sock) + "\n").encode()
            def observe(b):
                if not ready.is_set():
                    observed.extend(b)
                    if expected in observed.splitlines(keepends=True):
                        ready.set()
            def produce():
                try:
                    pair["producer"] = owned(label + "-producer", [str(producer), str(sock)] + ([flag] if flag else []), 35, observe)
                finally:
                    finished.set()
            t = threading.Thread(target=produce)
            t.start()
            try:
                until = time.monotonic() + 5
                while not ready.wait(0.02):
                    require(not finished.is_set() and time.monotonic() < until, "Producer did not reach exact READY")
                info = sock.lstat()
                require(stat.S_ISSOCK(info.st_mode) and info.st_uid == os.geteuid(), "Unsafe generated socket")
                pair["consumer"] = owned(label + "-consumer", [str(consumer), str(sock)]
                    + (["--expect-rejection"] if flag else []), 30)
            finally:
                t.join(timeout=50)
                pair["ownershipThreadJoined"] = not t.is_alive()
                pair["success"] = pair["ownershipThreadJoined"] and all(pair.get(p, {}).get("success") for p in ("producer", "consumer"))
                write(run / (label + ".pair.json"), pair)
                summary["pairs"].append({"label": label, "success": pair["success"],
                                         "receipt": str(run / (label + ".pair.json"))})
                if pair["success"]:
                    current_parent = endpoint.lstat()
                    require((current_parent.st_dev, current_parent.st_ino) == (parent.st_dev, parent.st_ino),
                            "Cleanup parent identity changed")
                    if sock.exists():
                        current = sock.lstat()
                        require(stat.S_ISSOCK(current.st_mode)
                                and (current.st_dev, current.st_ino) == (info.st_dev, info.st_ino),
                                "Cleanup socket identity changed")
                        sock.unlink()
                    endpoint.rmdir()
            require(pair["success"], label + " pair failed; generated endpoint preserved")
        summary["success"] = True
    except BaseException as error:
        summary["errors"].append(repr(error))
    finally:
        changed, after = [], []
        for record in before + [value["frozen"] for value in copies] + outputs:
            try:
                current = pin(Path(record["path"]))
                after.append(current)
                if current != record:
                    changed.append(record["path"])
            except OSError:
                changed.append(record["path"])
        write(run / "input-and-output-pins-after.json", after)
        summary.update(changedInputs=changed, immutableInputsUnchanged=not changed, compileResults=results)
        if changed:
            summary["success"] = False
        write(run / "result.json", summary)
        print(json.dumps(summary, indent=2))
    return 0 if summary["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
