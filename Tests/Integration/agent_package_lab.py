# SPDX-License-Identifier: Apache-2.0
"""Private test publisher for generic signed Linux payload; never carries enrollment."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
CONTEXT = b"macOpenVM Linux agent package v1\n"
SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def publish(binary, parent):
    """Caller owns private temporary parent. Returns generic payload and trusted issuer pin."""
    payloads, issuer = _publish((Path(binary),), parent, ("payload",))
    return payloads[0], issuer


def publish_generations(binary_a, binary_b, parent):
    """Sign exactly two compatible-manager test generations with one temporary issuer."""
    for source in (Path(binary_a), Path(binary_b)):
        if not source.is_file() or source.is_symlink():
            raise ValueError("Package source must be a regular local file")
    if sha(Path(binary_a)) == sha(Path(binary_b)):
        raise ValueError("Generation proof requires distinct agent binaries")
    return _publish((Path(binary_a), Path(binary_b)), parent, ("payload-a", "payload-b"))


def _publish(binaries, parent, labels):
    parent = Path(parent)
    if (parent.parent != Path("/private/tmp") or parent.is_symlink()
            or parent.stat().st_uid != os.geteuid() or parent.stat().st_mode & 0o7777 != 0o700):
        raise ValueError("Choose a private temporary publisher directory")
    if any(parent.iterdir()):
        raise ValueError("Publisher directory must be empty")
    sources = {"initd": ROOT / "GuestAgent/Linux/macopenvm-agent.initd",
               "setup.sh": ROOT / "GuestAgent/Linux/setup.sh"}
    for source in (*binaries, *sources.values()):
        if not source.is_file() or source.is_symlink():
            raise ValueError("Package source must be a regular local file")
    # Capture the manager once so A/B cannot silently use different manager bytes.
    shared = {name: source.read_bytes() for name, source in sources.items()}
    payloads = []
    for binary, label in zip(binaries, labels):
        payload = parent / label
        payload.mkdir(mode=0o700)
        shutil.copyfile(binary, payload / "agent")
        for name, data in shared.items():
            (payload / name).write_bytes(data)
        for path in payload.iterdir():
            path.chmod(0o600)
        manifest = b"".join((sha(payload / name) + "  " + name + "\n").encode()
                             for name in ("agent", "initd", "setup.sh"))
        (payload / "SHA256SUMS").write_bytes(manifest)
        payloads.append(payload)
    signed = parent / "signed-input"
    openssl = shutil.which("openssl")
    if not openssl:
        raise RuntimeError("Publisher tool unavailable")
    key = parent / ("publisher-key-" + uuid.uuid4().hex + ".pem")
    public = parent / "publisher-spki.der"
    def run(arguments):
        result = subprocess.run([openssl, *arguments], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=30)
        if result.returncode:
            raise RuntimeError("Private package signing failed")
    try:
        run(["genpkey", "-algorithm", "ED25519", "-out", str(key)])
        key.chmod(0o600)
        run(["pkey", "-in", str(key), "-pubout", "-outform", "DER", "-out", str(public)])
        der = public.read_bytes()
        if len(der) != 44 or not der.startswith(SPKI_PREFIX):
            raise RuntimeError("Unexpected standard Ed25519 public encoding")
        raw = der[len(SPKI_PREFIX):]
        for payload in payloads:
            signed.write_bytes(CONTEXT + (payload / "SHA256SUMS").read_bytes())
            run(["pkeyutl", "-sign", "-rawin", "-inkey", str(key), "-in", str(signed),
                 "-out", str(payload / "manifest.sig")])
            (payload / "issuer.raw").write_bytes(raw)
            for path in payload.iterdir():
                path.chmod(0o600)
        return tuple(payloads), hashlib.sha256(raw).hexdigest()
    finally:
        # Keys and transient signing material never enter the generic test packages.
        for path in (key, signed, public):
            path.unlink(missing_ok=True)
