"""Offline tests for isolated Terraform VM configurations."""

import json
import tempfile
import unittest
from pathlib import Path

from deployment.scripts.vm_instance_config import prepare, verify, vm_id_from_text


class InstanceConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "terraform.tfvars").write_text(
            'vm_ipv4_cidr = "10.20.20.20/24"\n'
            'vm_gateway = "10.20.20.1"\n',
            encoding="utf-8",
        )

    def test_prepare_is_idempotent_and_keeps_vm_isolated(self):
        self.assertEqual(prepare(self.root, 103, "25"), "10.20.20.25/24")
        self.assertEqual(prepare(self.root, 103, "25"), "10.20.20.25/24")
        self.assertEqual(prepare(self.root, 104, "26"), "10.20.20.26/24")
        self.assertEqual(verify(self.root, 103), "10.20.20.25/24")
        config = json.loads(
            (self.root / "instances/vm-103.tfvars.json").read_text()
        )
        self.assertEqual(config["vm_id"], 103)
        self.assertTrue(config["create_vm"])
        self.assertEqual(config["vm_name"], "job-market-ubuntu-103")

    def test_refuses_different_ip_for_same_vm(self):
        prepare(self.root, 103, "25")
        with self.assertRaisesRegex(ValueError, "different values"):
            prepare(self.root, 103, "26")
        self.assertEqual(verify(self.root, 103), "10.20.20.25/24")

    def test_refuses_duplicate_ip_across_vms(self):
        prepare(self.root, 103, "25")
        with self.assertRaisesRegex(ValueError, "already assigned"):
            prepare(self.root, 104, "25")

    def test_invalid_ids_octets_and_gateway(self):
        for text in ("99", "0", "-103", "0103", "nope"):
            with self.subTest(vm_id=text), self.assertRaises(ValueError):
                vm_id_from_text(text)
        for octet in ("0", "1", "255", "hello", "025"):
            with self.subTest(octet=octet), self.assertRaises(ValueError):
                prepare(self.root, 103, octet)

    def test_rejects_changed_subnet_and_mutated_identity(self):
        prepare(self.root, 103, "25")
        (self.root / "terraform.tfvars").write_text(
            'vm_ipv4_cidr = "10.20.30.20/24"\n'
            'vm_gateway = "10.20.30.1"\n'
        )
        with self.assertRaisesRegex(ValueError, "configured subnet"):
            verify(self.root, 103)
        config_file = self.root / "instances/vm-103.tfvars.json"
        data = json.loads(config_file.read_text())
        data["vm_id"] = 104
        config_file.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "mismatched"):
            verify(self.root, 103)


if __name__ == "__main__":
    unittest.main()
