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
import re
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
CATALOG_SCHEMA_VERSION = 2
ALLOWED_RANKING_CATEGORIES = {
    "attackers",
    "chargers",
    "closers",
    "consistency",
    "leads",
    "overall",
    "switches",
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


def git_value(environment_key, *git_args):
    override = os.environ.get(environment_key)
    if override:
        return override
    try:
        return subprocess.check_output(
            ["git", *git_args],
            cwd=REPO_ROOT,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        raise ValueError(f"Unable to resolve {environment_key}; set it explicitly")


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


def parity_metadata():
    source_tree = git_value(
        "PVPOKE_SOURCE_DATA_TREE_SHA",
        "rev-parse",
        "HEAD:src/data",
    )
    upstream_commit = git_value(
        "PVPOKE_UPSTREAM_COMMIT",
        "rev-parse",
        "upstream/master",
    )
    upstream_tree = git_value(
        "PVPOKE_UPSTREAM_DATA_TREE_SHA",
        "rev-parse",
        "upstream/master:src/data",
    )
    for label, value in (
        ("source data tree SHA", source_tree),
        ("upstream commit", upstream_commit),
        ("upstream data tree SHA", upstream_tree),
    ):
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
            raise ValueError(f"Invalid {label}: {value}")
    if source_tree != upstream_tree:
        raise ValueError(
            "Source data is not at exact upstream parity: "
            f"HEAD:src/data={source_tree}, upstream/master:src/data={upstream_tree}"
        )
    return upstream_commit, upstream_tree, source_tree


def utc_now():
    override = os.environ.get("PVPOKE_GENERATED_AT")
    if override:
        return override
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def payload_objects(dist=DIST):
    objects = []
    for root in (dist / "api", dist / "data"):
        for path in sorted(p for p in root.rglob("*") if p.is_file()):
            content = path.read_bytes()
            objects.append({
                "path": path.relative_to(dist).as_posix(),
                "size": len(content),
                "sha256": hashlib.sha256(content).hexdigest(),
                "md5": hashlib.md5(content).hexdigest(),
            })
    return objects


def hash_payload_objects(objects):
    digest = hashlib.sha256()
    for item in objects:
        digest.update(item["path"].encode("utf-8"))
        digest.update(b"\0")
        digest.update(item["sha256"].encode("ascii"))
        digest.update(b"\0")
        digest.update(str(item["size"]).encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def hash_dist_payload(dist=DIST):
    return hash_payload_objects(payload_objects(dist))


def generate_catalog(
    formats,
    manifest,
    source_commit,
    upstream_commit,
    upstream_data_tree_sha,
    source_data_tree_sha,
    objects,
    bundle_hash,
    generated_at,
    promoted_at,
):
    version = f"{source_data_tree_sha}-{bundle_hash}"
    return {
        "schemaVersion": CATALOG_SCHEMA_VERSION,
        "version": version,
        "sourceCommit": source_commit,
        "upstreamCommit": upstream_commit,
        "upstreamDataTreeSha": upstream_data_tree_sha,
        "sourceDataTreeSha": source_data_tree_sha,
        "objectCount": len(objects),
        "objects": objects,
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
        "schemaVersion": catalog["schemaVersion"],
        "version": catalog["version"],
        "sourceCommit": catalog["sourceCommit"],
        "upstreamCommit": catalog["upstreamCommit"],
        "upstreamDataTreeSha": catalog["upstreamDataTreeSha"],
        "sourceDataTreeSha": catalog["sourceDataTreeSha"],
        "objectCount": catalog["objectCount"],
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

    parsed_objects = {}
    for root in (dist / "api", dist / "data"):
        for path in sorted(root.rglob("*.json")):
            try:
                parsed_objects[path] = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError) as error:
                raise ValueError(f"Invalid JSON object: {path}: {error}") from error

    formats = parsed_objects[formats_path]
    manifest = parsed_objects[manifest_path]
    try:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"Invalid JSON object: {catalog_path}: {error}") from error

    format_ids = {(f.get("cup"), f.get("cp")) for f in formats if isinstance(f, dict)}
    missing_open = sorted(REQUIRED_OPEN_FORMATS - format_ids)
    if missing_open:
        raise ValueError(f"Missing required open formats: {missing_open}")

    entries = manifest.get("entries")
    if not isinstance(entries, list) or not entries:
        raise ValueError("Manifest must contain entries")
    for required in (
        "schemaVersion",
        "version",
        "sourceCommit",
        "upstreamCommit",
        "upstreamDataTreeSha",
        "sourceDataTreeSha",
        "objectCount",
        "objects",
        "bundleHash",
        "generatedAt",
        "promotedAt",
        "formats",
        "rankingAvailability",
        "paths",
    ):
        if required not in catalog:
            raise ValueError(f"Catalog missing {required}")

    if catalog["schemaVersion"] != CATALOG_SCHEMA_VERSION:
        raise ValueError(f"Catalog schemaVersion must be {CATALOG_SCHEMA_VERSION}")
    if catalog["sourceDataTreeSha"] != catalog["upstreamDataTreeSha"]:
        raise ValueError("Catalog sourceDataTreeSha does not match upstreamDataTreeSha")
    for field in ("sourceCommit", "upstreamCommit", "upstreamDataTreeSha", "sourceDataTreeSha"):
        value = catalog[field]
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
            raise ValueError(f"Catalog {field} is not a full Git SHA")

    if catalog["formats"] != formats:
        raise ValueError("Catalog formats do not match api/formats.json")
    manifest_paths = []
    manifest_keys = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("Manifest entries must be objects")
        try:
            cup = entry["cup"]
            cp = entry["cp"]
            category = entry["category"]
            raw_path = entry["path"]
        except KeyError as error:
            raise ValueError(f"Manifest entry missing {error.args[0]}") from error
        expected_path = f"/data/rankings/{cup}/{category}/rankings-{cp}.json"
        if category not in ALLOWED_RANKING_CATEGORIES:
            raise ValueError(f"Manifest category is not supported: {category}")
        if raw_path != expected_path:
            raise ValueError(f"Manifest path does not match its cup/category/cp: {raw_path}")
        path = dist / raw_path.lstrip("/")
        if not path.exists():
            raise ValueError(f"Manifest references missing ranking object: {raw_path}")
        ranking = parsed_objects[path]
        if not isinstance(ranking, list) or not ranking:
            raise ValueError(f"Ranking object must be a non-empty array: {raw_path}")
        species_ids = []
        for row in ranking:
            if not isinstance(row, dict) or not isinstance(row.get("speciesId"), str):
                raise ValueError(f"Ranking object has invalid speciesId rows: {raw_path}")
            species_ids.append(row["speciesId"])
        if len(species_ids) != len(set(species_ids)):
            raise ValueError(f"Ranking object has duplicate speciesId rows: {raw_path}")
        manifest_paths.append(raw_path)
        manifest_keys.append((cup, cp, category))

    if len(manifest_keys) != len(set(manifest_keys)) or len(manifest_paths) != len(set(manifest_paths)):
        raise ValueError("Manifest contains duplicate entries")
    if catalog["rankingAvailability"] != entries:
        raise ValueError("Catalog rankingAvailability does not match manifest entries")

    actual_ranking_paths = sorted(
        f"/{path.relative_to(dist).as_posix()}"
        for path in (dist / "data" / "rankings").glob("*/*/rankings-*.json")
    )
    if sorted(manifest_paths) != actual_ranking_paths:
        missing = sorted(set(actual_ranking_paths) - set(manifest_paths))
        extra = sorted(set(manifest_paths) - set(actual_ranking_paths))
        raise ValueError(f"Ranking manifest is not exhaustive; missing={missing}, extra={extra}")

    actual_objects = payload_objects(dist)
    actual_count = len(actual_objects)
    if catalog["objectCount"] != actual_count:
        raise ValueError(
            f"Catalog objectCount is {catalog['objectCount']}, expected {actual_count}"
        )
    if catalog["objects"] != actual_objects:
        raise ValueError("Catalog objects do not match the generated payload")
    actual_hash = hash_payload_objects(actual_objects)
    if catalog["bundleHash"] != actual_hash:
        raise ValueError(f"Catalog bundleHash is {catalog['bundleHash']}, expected {actual_hash}")
    expected_version = f"{catalog['sourceDataTreeSha']}-{actual_hash}"
    if catalog["version"] != expected_version:
        raise ValueError(f"Catalog version is {catalog['version']}, expected {expected_version}")


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--validate-only", action="store_true", help="validate an already generated dist directory")
    args = parser.parse_args(argv)

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
    upstream_commit, upstream_data_tree_sha, source_data_tree_sha = parity_metadata()
    generated_at = utc_now()
    promoted_at = os.environ.get("PVPOKE_PROMOTED_AT", generated_at)
    objects = payload_objects()
    bundle_hash = hash_payload_objects(objects)
    catalog = generate_catalog(
        formats,
        manifest,
        source_commit,
        upstream_commit,
        upstream_data_tree_sha,
        source_data_tree_sha,
        objects,
        bundle_hash,
        generated_at,
        promoted_at,
    )

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
