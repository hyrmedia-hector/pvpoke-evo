#!/usr/bin/env python3
"""
Generate API files for the PvPoke Static Data Mirror.

Produces:
  - dist/api/formats.json          (merged open leagues + gamemaster formats)
  - dist/data/rankings/manifest-native.json  (complete index of all ranking files)
  - dist/v1/catalog.json           (versioned API catalog consumed by the Worker)
  - dist/current.json              (small pointer promoted atomically in R2)

Also copies the static data tree into dist/ for deployment.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
SRC_DATA = REPO_ROOT / "src" / "data"
DIST = REPO_ROOT / "dist"
DIST_API = DIST / "api"
DIST_V1 = DIST / "v1"
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

REQUIRED_OPEN_FORMATS = {
    ("all", 1500),
    ("all", 2500),
    ("all", 10000),
}


def load_gamemaster():
    with open(SRC_DATA / "gamemaster.json", encoding="utf-8") as f:
        return json.load(f)


def generate_formats(gm):
    """Return open leagues first, then every format defined in gamemaster.json."""
    return list(OPEN_FORMATS) + list(gm.get("formats", []))


def generate_manifest(gm):
    """Walk the rankings tree and build a manifest of every rankings-*.json file."""
    # Build lookup from (cup, cp) -> title using merged open leagues + gamemaster formats
    all_formats = generate_formats(gm)
    title_lookup = {
        (f["cup"], f["cp"]): f["title"]
        for f in all_formats
    }
    entries = []

    rankings_dir = SRC_DATA / "rankings"
    if not rankings_dir.exists():
        return {"entries": entries}

    for cup_dir in rankings_dir.iterdir():
        if not cup_dir.is_dir():
            continue
        cup = cup_dir.name

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

                cup_title = title_lookup.get((cup, cp), cup)

                entries.append({
                    "cup": cup,
                    "cupTitle": cup_title,
                    "cp": cp,
                    "category": category,
                    "isAvailable": True,
                    "source": "liveFormats",
                    "path": f"/data/rankings/{cup}/{category}/rankings-{cp}.json",
                })

    # Deterministic sort so diffs are stable
    entries.sort(key=lambda e: (e["cup"], e["cp"], e["category"]))
    return {"entries": entries}


def git_commit():
    override = os.environ.get("PVPOKE_SOURCE_COMMIT") or os.environ.get("GITHUB_SHA")
    if override:
        return override
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=REPO_ROOT,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        return "unknown"


def utc_now():
    override = os.environ.get("PVPOKE_GENERATED_AT")
    if override:
        return override
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def hash_dist_payload():
    digest = hashlib.sha256()
    for root in (DIST_API, DIST_DATA):
        for path in sorted(p for p in root.rglob("*") if p.is_file()):
            rel = path.relative_to(DIST).as_posix()
            digest.update(rel.encode("utf-8"))
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
    return digest.hexdigest()


def generate_catalog(formats, manifest, source_commit, bundle_hash, generated_at, promoted_at):
    version = f"{source_commit}-{bundle_hash}"
    return {
        "version": version,
        "sourceCommit": source_commit,
        "bundleHash": bundle_hash,
        "generatedAt": generated_at,
        "promotedAt": promoted_at,
        "formats": formats,
        "rankingAvailability": manifest["entries"],
        "paths": {
            "gameMaster": "/data/gamemaster.min.json",
            "formats": "/api/formats.json",
            "rankingManifest": "/data/rankings/manifest-native.json",
            "rankingsBase": "/data/rankings",
        },
    }


def generate_current_pointer(catalog):
    return {
        "version": catalog["version"],
        "sourceCommit": catalog["sourceCommit"],
        "bundleHash": catalog["bundleHash"],
        "generatedAt": catalog["generatedAt"],
        "promotedAt": catalog["promotedAt"],
        "catalogKey": f"versions/{catalog['version']}/v1/catalog.json",
    }


def copy_static_data():
    """Mirror src/data into dist/data for deployment."""
    if DIST_DATA.exists():
        shutil.rmtree(DIST_DATA)
    shutil.copytree(SRC_DATA, DIST_DATA)


def validate_generated_files(dist=DIST):
    formats_path = dist / "api" / "formats.json"
    manifest_path = dist / "data" / "rankings" / "manifest-native.json"
    catalog_path = dist / "v1" / "catalog.json"

    for path in (formats_path, manifest_path, catalog_path, dist / "data" / "gamemaster.min.json"):
        if not path.exists():
            raise ValueError(f"Missing generated file: {path}")

    formats = json.loads(formats_path.read_text(encoding="utf-8"))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))

    format_ids = {(f.get("cup"), f.get("cp")) for f in formats if isinstance(f, dict)}
    missing_open = sorted(REQUIRED_OPEN_FORMATS - format_ids)
    if missing_open:
        raise ValueError(f"Missing required open formats: {missing_open}")

    entries = manifest.get("entries")
    if not isinstance(entries, list) or not entries:
        raise ValueError("Manifest must contain entries")

    for required in ("version", "sourceCommit", "bundleHash", "generatedAt", "promotedAt", "formats", "rankingAvailability", "paths"):
        if required not in catalog:
            raise ValueError(f"Catalog missing {required}")

    if catalog["formats"] != formats:
        raise ValueError("Catalog formats do not match api/formats.json")
    if catalog["rankingAvailability"] != entries:
        raise ValueError("Catalog rankingAvailability does not match manifest entries")

    representative = [
        dist / "data" / "rankings" / "all" / "overall" / "rankings-1500.json",
        dist / "data" / "rankings" / "all" / "overall" / "rankings-2500.json",
        dist / "data" / "rankings" / "all" / "overall" / "rankings-10000.json",
    ]
    for path in representative:
        if not path.exists():
            raise ValueError(f"Missing representative ranking file: {path}")
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, list) or not data or "speciesId" not in data[0]:
            raise ValueError(f"Representative ranking file has invalid shape: {path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--validate-only", action="store_true", help="validate an already generated dist directory")
    args = parser.parse_args()

    if args.validate_only:
        validate_generated_files()
        print("Generated API files are valid.")
        return 0

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

    source_commit = git_commit()
    generated_at = utc_now()
    promoted_at = os.environ.get("PVPOKE_PROMOTED_AT", generated_at)
    bundle_hash = hash_dist_payload()
    catalog = generate_catalog(formats, manifest, source_commit, bundle_hash, generated_at, promoted_at)

    DIST_V1.mkdir(parents=True, exist_ok=True)
    with open(DIST_V1 / "catalog.json", "w", encoding="utf-8") as f:
        json.dump(catalog, f, indent=2)
        f.write("\n")

    with open(DIST / "current.json", "w", encoding="utf-8") as f:
        json.dump(generate_current_pointer(catalog), f, indent=2)
        f.write("\n")

    validate_generated_files()

    print(
        f"Done. {len(formats)} formats, {len(manifest['entries'])} manifest entries."
    )
    print(f"Version: {catalog['version']}")
    print(f"Deploy directory: {DIST}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
