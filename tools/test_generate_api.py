import copy
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("generate-api.py")
MODULE_SPEC = importlib.util.spec_from_file_location("generate_api", MODULE_PATH)
assert MODULE_SPEC and MODULE_SPEC.loader
generate_api = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(generate_api)


class GeneratedBundleValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        generate_api.main([])

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.dist = Path(self.temp_dir.name) / "dist"
        shutil.copytree(generate_api.DIST, self.dist)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_generated_catalog_carries_exact_upstream_parity_proof(self):
        catalog = json.loads((self.dist / "v1" / "catalog.json").read_text())

        self.assertEqual(catalog["schemaVersion"], 2)
        self.assertRegex(catalog["upstreamCommit"], r"^[0-9a-f]{40}$")
        self.assertRegex(catalog["upstreamDataTreeSha"], r"^[0-9a-f]{40}$")
        self.assertEqual(catalog["sourceDataTreeSha"], catalog["upstreamDataTreeSha"])
        self.assertEqual(catalog["objectCount"], self._payload_object_count())

    def test_validation_rejects_a_manifest_entry_whose_object_is_missing(self):
        manifest_path = self.dist / "data" / "rankings" / "manifest-native.json"
        manifest = json.loads(manifest_path.read_text())
        victim = manifest["entries"][0]
        relative_path = victim["path"].lstrip("/")
        (self.dist / relative_path).unlink()

        with self.assertRaisesRegex(ValueError, "Manifest references missing ranking object"):
            generate_api.validate_generated_files(self.dist)

    def test_validation_rejects_an_unindexed_ranking_object(self):
        source = self.dist / "data" / "rankings" / "all" / "overall" / "rankings-1500.json"
        extra = self.dist / "data" / "rankings" / "all" / "overall" / "rankings-1499.json"
        shutil.copy(source, extra)

        with self.assertRaisesRegex(ValueError, "Ranking manifest is not exhaustive"):
            generate_api.validate_generated_files(self.dist)

    def test_validation_rejects_any_invalid_json_object(self):
        path = self.dist / "data" / "groups" / "great.json"
        path.write_text("{not json", encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "Invalid JSON object"):
            generate_api.validate_generated_files(self.dist)

    def test_validation_rejects_duplicate_manifest_entries(self):
        manifest_path = self.dist / "data" / "rankings" / "manifest-native.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["entries"].append(copy.deepcopy(manifest["entries"][0]))
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "duplicate entries"):
            generate_api.validate_generated_files(self.dist)

    def test_validation_recomputes_bundle_hash(self):
        catalog_path = self.dist / "v1" / "catalog.json"
        catalog = json.loads(catalog_path.read_text())
        catalog["bundleHash"] = "0" * 64
        catalog_path.write_text(json.dumps(catalog), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "bundleHash"):
            generate_api.validate_generated_files(self.dist)

    def test_validation_recomputes_object_count(self):
        catalog_path = self.dist / "v1" / "catalog.json"
        catalog = json.loads(catalog_path.read_text())
        catalog["objectCount"] += 1
        catalog_path.write_text(json.dumps(catalog), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "objectCount"):
            generate_api.validate_generated_files(self.dist)

    def _payload_object_count(self):
        return sum(
            1
            for root in (self.dist / "api", self.dist / "data")
            for path in root.rglob("*")
            if path.is_file()
        )

    def test_validation_rejects_an_unknown_ranking_category(self):
        manifest_path = self.dist / "data" / "rankings" / "manifest-native.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["entries"][0]["category"] = "mystery"
        manifest["entries"][0]["path"] = manifest["entries"][0]["path"].replace(
            "/attackers/", "/mystery/"
        )
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "category is not supported"):
            generate_api.validate_generated_files(self.dist)


if __name__ == "__main__":
    unittest.main()
