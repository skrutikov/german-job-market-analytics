"""Offline VM-targeted backup checks; no real SSH or Proxmox used."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class BackupTargetTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in ("deployment/scripts", "deployment/dr", "deployment/terraform"):
            (self.root / directory).mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()

        for name in ("create_backup.sh", "terraform_vm_workspace.sh"):
            shutil.copyfile(
                ROOT / "deployment" / "scripts" / name,
                self.root / "deployment" / "scripts" / name,
            )
        for name in ("common.sh", "maintenance.sh"):
            shutil.copyfile(
                ROOT / "deployment" / "dr" / name,
                self.root / "deployment" / "dr" / name,
            )
        self.identity = self.root / "identity.txt"
        self.identity.write_text("test-only\n")
        self.private_key = self.root / "vm-key"
        self.private_key.write_text("test-only\n")
        self.ssh_calls = self.root / "ssh-calls.txt"

        self.mock(
            "terraform",
            """#!/usr/bin/env bash
case "$*" in
  *"init -input=false"*) : ;;
  *"workspace list"*) printf '  default\\n* vm-103\\n' ;;
  *"workspace select vm-103"*) : ;;
  *"workspace show"*) echo vm-103 ;;
  *"state list"*) echo 'proxmox_virtual_environment_vm.k3s[0]' ;;
  *"managed_vm_id"*) echo "$MOCK_MANAGED_ID" ;;
  *"managed_vm_name"*) echo job-market-ubuntu-103 ;;
  *"managed_vm_ipv4"*) echo 10.10.10.27/24 ;;
  *"managed_vm_username"*) echo group3 ;;
  *"managed_vm_ssh_public_key_path"*) echo "$MOCK_SSH_PUB" ;;
  *) echo "Unexpected Terraform: $*" >&2; exit 9 ;;
esac
""",
        )
        self.mock(
            "ssh",
            """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$MOCK_SSH_CALLS"
case "$*" in
  *"kubectl get nodes -o name"*) : ;;
  *"hostname"*) echo wrong-host ;;
  *"items[0].metadata.name"*) echo job-market-ubuntu-103 ;;
  *) echo "Unexpected SSH: $*" >&2; exit 9 ;;
esac
""",
        )
        self.mock("age-keygen", "#!/usr/bin/env bash\necho age1testrecipient\n")
        self.mock("age", "#!/usr/bin/env bash\ncat\n")

    def mock(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_backup(self, *args, managed_id="103"):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin}:{env['PATH']}",
                "DR_IDENTITY": str(self.identity),
                "MOCK_MANAGED_ID": managed_id,
                "MOCK_SSH_PUB": str(self.private_key) + ".pub",
                "MOCK_SSH_CALLS": str(self.ssh_calls),
            }
        )
        env.pop("TF_WORKSPACE", None)
        return subprocess.run(
            [
                "bash",
                str(self.root / "deployment" / "scripts" / "create_backup.sh"),
                *args,
            ],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_refuses_wrong_state_without_ssh(self):
        result = self.run_backup("103", "dev", managed_id="104")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match Terraform state", result.stderr)
        self.assertFalse(self.ssh_calls.exists())

    def test_checks_guest_identity_at_workspace_ip(self):
        result = self.run_backup("103", "dev")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Backup destination mismatch", result.stderr)
        self.assertIn("group3@10.10.10.27", self.ssh_calls.read_text())

    def test_rejects_unknown_namespace(self):
        result = self.run_backup("103", "staging")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Namespace must be dev or prod", result.stderr)
        self.assertFalse(self.ssh_calls.exists())


if __name__ == "__main__":
    unittest.main()
