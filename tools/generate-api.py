#!/usr/bin/env python3
"""
Generate API files for the PvPoke Static Data Mirror.

Produces:
  - dist/api/formats.json          (merged open leagues + gamemaster formats)
  - dist/data/rankings/manifest-native.json  (complete index of all ranking files)

Also copies the static data tree into dist/ for deployment.
"""

import json
import os
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
SRC_DATA = REPO_ROOT / "src" / "data"
DIST = REPO_ROOT / "dist"
DIST_API = DIST / "api"
DIST_DATA = DIST / "data"
DIST_RANKINGS = DIST_DATA / "rankings"

# Open league formats that the reference site hardcodes in the HTML.
# The mobile app currently scrapes these from the rankings page.
OPEN_FORMATS = [
    {
        "title": "Great League",
        "cup": "all",
        "cp": 1500,
        "meta": "great",
        "showCup": True,
        "showFormat": True,
        "showMeta": True,
    },
    {
        "title": "Ultra League",
        "cup": "all",
        "cp": 2500,
        "meta": "ultra",
        "showCup": True,
        "showFormat": True,
        "showMeta": True,
    },
    {
        "title": "Master League",
        "cup": "all",
        "cp": 10000,
        "meta": "master",
        "showCup": True,
        "showFormat": True,
        "showMeta": True,
    },
]


def load_gamemaster():
    with open(SRC_DATA / "gamemaster.json", encoding="utf-8") as f:
        return json.load(f)


def generate_formats(gm):
    """Return open leagues first, then every format defined in gamemaster.json."""
    return list(OPEN_FORMATS) + list(gm.get("formats", []))


def generate_manifest(gm):
    """Walk the rankings tree and build a manifest of every rankings-*.json file."""
    formats_lookup = {f["cup"]: f for f in gm.get("formats", [])}
    entries = []

    rankings_dir = SRC_DATA / "rankings"
    if not rankings_dir.exists():
        return {"entries": entries}

    for cup_dir in rankings_dir.iterdir():
        if not cup_dir.is_dir():
            continue
        cup = cup_dir.name
        cup_title = formats_lookup.get(cup, {}).get("title", cup)
        # Provide human-readable titles for open-league cups
        if cup == "all":
            cup_title = "All Pokémon"

        for category_dir in cup_dir.iterdir():
            if not category_dir.is_dir():
                continue
            category = category_dir.name

            for ranking_file in category_dir.glob("rankings-*.json"):
                # filename pattern: rankings-{cp}.json
                stem = ranking_file.stem  # e.g. "rankings-1500"
                if not stem.startswith("rankings-"):
                    continue
                cp_str = stem[len("rankings-"):]
                try:
                    cp = int(cp_str)
                except ValueError:
                    continue

                entries.append({
                    "cup": cup,
                    "cupTitle": cup_title,
                    "cp": cp,
                    "category": category,
                    "isAvailable": True,
                    "source": "liveFormats",
                })

    # Deterministic sort so diffs are stable
    entries.sort(key=lambda e: (e["cup"], e["cp"], e["category"]))
    return {"entries": entries}


def copy_static_data():
    """Mirror src/data into dist/data for deployment."""
    if DIST_DATA.exists():
        shutil.rmtree(DIST_DATA)
    shutil.copytree(SRC_DATA, DIST_DATA)


def main():
    print("Loading gamemaster...")
    gm = load_gamemaster()

    print("Generating formats...")
    formats = generate_formats(gm)

    print("Generating manifest...")
    manifest = generate_manifest(gm)

    print("Copying static data...")
    copy_static_data()

    # Write generated API files into dist/
    DIST_API.mkdir(parents=True, exist_ok=True)
    with open(DIST_API / "formats.json", "w", encoding="utf-8") as f:
        json.dump(formats, f, indent=2)
        f.write("\n")

    # Manifest lives inside the rankings tree so the app's existing path logic works
    with open(DIST_RANKINGS / "manifest-native.json", "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")

    print(
        f"Done. {len(formats)} formats, {len(manifest['entries'])} manifest entries."
    )
    print(f"Deploy directory: {DIST}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
