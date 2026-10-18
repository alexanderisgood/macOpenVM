#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Extract production/historical Metal literals without rewriting shader bodies."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import textwrap


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def literal(raw, name):
    pattern = r'\b(?:static\s+)?let\s+' + re.escape(name) + r'\s*=\s*"""\n(.*?)\n[ \t]*"""'
    matches = re.findall(pattern, raw.decode(), re.S)
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one literal named {name}")
    shader = textwrap.dedent(matches[0]) + "\n"
    if '\\(' in shader:
        raise ValueError("Swift interpolation cannot be extracted literally")
    return shader.encode()


def extract(production, original, output):
    # Exclusive outputs make source identity errors explicit instead of replacing
    # an earlier experiment's shaders. Caller supplies a fresh output directory.
    output.mkdir(mode=0o700)
    current_raw, original_raw = production.read_bytes(), original.read_bytes()
    base, sharp, old = literal(current_raw, "shader"), literal(current_raw, "sharpeningShader"), literal(original_raw, "shader")
    for raw, names in [(base, ("plane", "opaque")), (sharp, ("plane", "lightSharp")), (old, ("plane", "opaque"))]:
        for name in names:
            if not re.search(rb"\b" + name.encode() + rb"\s*\(", raw):
                raise ValueError(f"Missing shader entry point {name}")
    if base != old:
        raise ValueError("Default shader literal changed from the supplied historical source")
    outputs = {}
    for name, raw in [("baseline.metal", base), ("sharpening.metal", sharp), ("original.metal", old)]:
        path = output / name
        with path.open("xb") as stream:
            stream.write(raw)
        outputs[name] = {"path": str(path.resolve()), "sha256": digest(raw), "bytes": len(raw)}
    return {"schemaVersion": 1, "productionSource": str(production.resolve()),
            "productionSourceSHA256": digest(current_raw), "originalSource": str(original.resolve()),
            "originalSourceSHA256": digest(original_raw), "defaultShaderByteExact": True,
            "separateShaderLibraries": True, "outputs": outputs, "nativeExecutionPerformed": False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("production_swift", type=Path)
    parser.add_argument("original_swift", type=Path)
    parser.add_argument("fresh_output_directory", type=Path)
    args = parser.parse_args()
    print(json.dumps(extract(args.production_swift, args.original_swift, args.fresh_output_directory), indent=2))


if __name__ == "__main__":
    main()
