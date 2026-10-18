#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Deterministic SPDX inventory; intentionally does not claim release clearance."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true", help="Verify the checked-in inventory without rewriting it")
arguments = parser.parse_args()
manifest = json.loads((ROOT / "dependencies.json").read_text())
required = {"name", "version", "sourceURL", "license", "modifications", "scope", "redistributed", "obligations"}
packages = []
extracted = []
for index, component in enumerate(manifest["components"]):
    if required - component.keys():
        raise SystemExit("Incomplete dependency record")
    if component["redistributed"] and (component["license"] == "NOASSERTION" or component["version"] == "NOASSERTION"):
        raise SystemExit("Unreviewed redistributed component")
    license_id = component["license"]
    if license_id.startswith("LicenseRef-"):
        extracted.append({"licenseId": license_id, "extractedText": "NOASSERTION", "comment": component["obligations"]})
    packages.append({
        "SPDXID": f"SPDXRef-Package-{index}", "name": component["name"],
        "versionInfo": component["version"], "downloadLocation": component["sourceURL"],
        "filesAnalyzed": False, "licenseConcluded": "NOASSERTION", "licenseDeclared": license_id,
        "copyrightText": component.get("copyrightText", "NOASSERTION"), "comment": json.dumps({
            key: component[key] for key in ["modifications", "scope", "redistributed", "obligations"]}, sort_keys=True),
    })
digest = hashlib.sha256((ROOT / "dependencies.json").read_bytes()).hexdigest()
document = {
    "spdxVersion": "SPDX-2.3", "dataLicense": "CC0-1.0", "SPDXID": "SPDXRef-DOCUMENT",
    "name": "macOpenVM development inventory",
    "documentNamespace": f"urn:uuid:{digest[:8]}-{digest[8:12]}-4{digest[13:16]}-a{digest[17:20]}-{digest[20:32]}",
    "creationInfo": {"created": "2026-10-06T00:00:00Z", "creators": ["Tool: macOpenVM sbom.py v1"]},
    "documentComment": manifest["scope"] + " Release clearance: false. Inventory timestamp fixed for deterministic generation.",
    "packages": packages,
    "relationships": [{"spdxElementId": "SPDXRef-DOCUMENT", "relatedSpdxElement": "SPDXRef-Package-0", "relationshipType": "DESCRIBES"}],
    "hasExtractedLicensingInfos": extracted,
}
rendered = json.dumps(document, indent=2, sort_keys=True) + "\n"
destination = ROOT / "sbom.spdx.json"
if arguments.check:
    if not destination.is_file() or destination.read_text() != rendered:
        raise SystemExit("Development SPDX inventory is out of date. Review dependencies.json, then run python3 scripts/sbom.py.")
    print("Development SPDX inventory matches; no files changed.")
else:
    destination.write_text(rendered)
    print("Development SPDX inventory generated; unadopted evaluation dependencies remain review gates.")
