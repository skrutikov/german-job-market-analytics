"""Unit tests for safe, paired GitOps image pinning."""

import shutil
import tempfile
import unittest
from pathlib import Path

from release_images import check, read_tags, set_tags

BASE = Path(__file__).resolve().parent.parent
EXISTING_SHA = "f6777a134a2be7273430976cf68b58810340dd62"
NEW_SHA = "fcb77a1bb0cae52147f34148164d421e666563fa"


class ReleaseImagesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for environment in ("dev", "prod"):
            target = self.root / "kubernetes" / "overlays" / environment
            target.mkdir(parents=True)
            shutil.copyfile(
                BASE / "kubernetes" / "overlays" / environment / "kustomization.yaml",
                target / "kustomization.yaml",
            )

    def test_dev_tag_updates_both_images_without_touching_prod(self):
        prod_before = read_tags(self.root, "prod")
        self.assertTrue(set_tags(self.root, "dev", NEW_SHA))
        check(self.root, "dev", NEW_SHA)
        self.assertFalse(set_tags(self.root, "dev", NEW_SHA))
        self.assertEqual(read_tags(self.root, "prod"), prod_before)

    def test_promotion_must_match_tested_dev_tag(self):
        with self.assertRaises(ValueError):
            check(self.root, "dev", NEW_SHA)
        set_tags(self.root, "dev", NEW_SHA)
        check(self.root, "dev", NEW_SHA)
        set_tags(self.root, "prod", NEW_SHA)
        check(self.root, "prod", NEW_SHA)

    def test_reject_malformed_shas(self):
        for invalid in ("main", "abc", "A" * 40, "a" * 39, "a" * 41, "a" * 40 + ";oops"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                set_tags(self.root, "dev", invalid)

    def test_reject_extra_image_entry(self):
        path = self.root / "kubernetes/overlays/dev/kustomization.yaml"
        path.write_text(path.read_text() + "  - name: malicious/image\n    newTag: main\n")
        with self.assertRaises(ValueError):
            set_tags(self.root, "dev", EXISTING_SHA)

    def test_preserve_other_overlay_fields(self):
        path = self.root / "kubernetes/overlays/dev/kustomization.yaml"
        before = path.read_text()
        set_tags(self.root, "dev", NEW_SHA)
        after = path.read_text()
        self.assertEqual(before.split("images:")[0], after.split("images:")[0])


if __name__ == "__main__":
    unittest.main()
