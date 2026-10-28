#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SovaGrid — Copyright (C) 2026 Jigokuraku01
# Additional attribution terms: see ATTRIBUTION.md.
"""Check pinned dependency notices and their presence in built Apple apps."""

import hashlib
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "SovaGrid/LegalResources"
PINS = ROOT / "SovaGrid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify():
    pins = {pin["identity"]: pin for pin in json.loads(PINS.read_text())["pins"]}
    manifest = json.loads((RESOURCES / "ThirdParty/manifest.json").read_text())
    assert manifest["schema"] == 1
    packages = manifest["packages"]
    assert len(packages) == len(pins)
    assert {item["package"] for item in packages} == set(pins)
    expected = set()
    for package in packages:
        pin = pins[package["package"]]
        assert package["version"] == pin["state"]["version"], package["package"]
        assert package["revision"] == pin["state"]["revision"], package["package"]
        assert package["source"] == pin["location"], package["package"]
        assert package["files"], package["package"]
        for item in package["files"]:
            relative = Path(item["path"])
            assert relative.parts[:1] == ("ThirdParty",) and ".." not in relative.parts
            assert digest(RESOURCES / relative) == item["sha256"], relative
            expected.add(relative)
    actual = {path.relative_to(RESOURCES) for path in (RESOURCES / "ThirdParty").rglob("*")
              if path.is_file() and path.name != "manifest.json"}
    assert expected == actual, "Unindexed or missing dependency notice"
    for name in ("LICENSE", "NOTICE", "ATTRIBUTION.md"):
        assert (ROOT / name).read_bytes() == (RESOURCES / name).read_bytes(), name

    source_files = {path.relative_to(RESOURCES): digest(path)
                    for path in RESOURCES.rglob("*") if path.is_file()}
    for argument in sys.argv[1:]:
        app = Path(argument).resolve()
        # Bundle.main.resourceURL maps to Contents/Resources on macOS and the
        # application root on iOS; verify both actual product layouts.
        resources = app / "Contents/Resources" if (app / "Contents").is_dir() else app
        destination = resources / "LegalResources"
        packaged_files = {path.relative_to(destination): digest(path)
                          for path in destination.rglob("*") if path.is_file()}
        assert source_files == packaged_files, f"Incomplete or stale notices in {app}"
        print(f"PASS exact offline legal resources: {app.name}")
    print(f"PASS {len(packages)} pinned packages, {len(expected)} exact dependency notice files")


if __name__ == "__main__":
    verify()
