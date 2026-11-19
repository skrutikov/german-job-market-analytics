"""Offline terminal-output tests for deployment; never contact Proxmox."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


DEPLOY = Path(__file__).resolve().parent.parent / "scripts" / "deploy.sh"


class DeployTerminalMessagesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cert = self.root / "pve-root-ca.pem"
        self.cert.write_text("mock certificate\n")
        self.private_key = self.root / "id_ed25519"
        self.private_key.write_text("mock private key\n")
        (self.root / "id_ed25519.pub").write_text("mock public key\n")
        self.ssh_calls = self.root / "ssh-calls.txt"

        self.mock(
            "terraform",
            """#!/usr/bin/env bash
case "$*" in
  *"init -input=false"*) exit 0 ;;
  *"workspace list"*) printf '  default\\n* vm-103\\n' ;;
  *"workspace select vm-103"*) exit 0 ;;
  *"workspace show"*) echo vm-103 ;;
  *"console"*)
    read -r variable
    case "$variable" in
      var.vm_ipv4_cidr) echo '"10.10.10.20/24"' ;;
      var.vm_gateway) echo '"10.10.10.1"' ;;
      *) exit 9 ;;
    esac ;;
  *"state list"*) exit 0 ;;
  *"validate"*) exit 0 ;;
  *"plan "*) exit 0 ;;
  *"show -json"*)
    cat <<'JSON'
{"resource_changes":[{"address":"proxmox_virtual_environment_vm.k3s[0]","change":{"actions":["create"],"after":{"vm_id":103}}}],"planned_values":{"outputs":{"managed_vm_ipv4":{"value":"10.10.10.27/24"}}}}
JSON
    ;;
  *"apply "*) exit 0 ;;
  *"output -raw managed_vm_id"*) echo 103 ;;
  *"output -raw managed_vm_ipv4"*) echo 10.10.10.27/24 ;;
  *"output -raw managed_vm_username"*) echo group3 ;;
  *"output -raw managed_vm_ssh_public_key_path"*) echo "$MOCK_SSH_PUB" ;;
  *) echo "Unexpected Terraform call: $*" >&2; exit 9 ;;
esac
""",
        )
        self.mock(
            "ssh",
            """#!/usr/bin/env bash
printf 'SSH attempt\\n' >> "$MOCK_SSH_CALLS"
if [[ "$MOCK_SSH_MODE" == changed ]]; then
  echo 'WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!' >&2
  exit 255
fi
exit 0
""",
        )
        self.mock("ansible", "#!/usr/bin/env bash\nexit 0\n")
        self.mock("ansible-playbook", "#!/usr/bin/env bash\nexit 0\n")
        self.mock(
            "sleep",
            "#!/usr/bin/env bash\n"
            'echo "Unexpected SSH retry" >&2\n'
            "exit 99\n",
        )

    def mock(self, name, body):
        path = self.root / name
        path.write_text(body)
        path.chmod(0o755)

    def run_deployment(self, ssh_mode):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.root}:{env['PATH']}",
                "SSL_CERT_FILE": str(self.cert),
                "PROXMOX_VE_API_TOKEN": "root1@pve!terraform=offline-test",
                "MOCK_SSH_MODE": ssh_mode,
                "MOCK_SSH_PUB": str(self.private_key) + ".pub",
                "MOCK_SSH_CALLS": str(self.ssh_calls),
            }
        )
        env.pop("TF_WORKSPACE", None)
        return subprocess.run(
            ["bash", str(DEPLOY), "103", "27", "dev", "--infra-only"],
            input="apply 103\n",
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_permissions_reminder_and_concise_success_summary(self):
        result = self.run_deployment("ok")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pveum acl modify /vms/103 \\", result.stdout)
        self.assertIn("--tokens 'root1@pve!terraform'", result.stdout)
        self.assertLess(
            result.stdout.index("PROXMOX VM PERMISSIONS"),
            result.stdout.index("Target VM 103"),
        )
        self.assertIn("DEPLOYMENT COMPLETE", result.stdout)
        self.assertIn("IP address:  10.10.10.27", result.stdout)
        self.assertIn("Environment: dev", result.stdout)
        self.assertIn("Workspace:   vm-103", result.stdout)
        self.assertNotIn("SSH HOST KEY CHANGED", result.stdout)

    def test_changed_host_key_stops_without_retry_or_key_removal(self):
        result = self.run_deployment("changed")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SSH HOST KEY CHANGED", result.stderr)
        self.assertIn("ssh-keygen -R 10.10.10.27", result.stderr)
        self.assertIn("ONLY after verifying", result.stderr)
        self.assertIn("ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub", result.stderr)
        self.assertNotIn("Unexpected SSH retry", result.stderr)
        self.assertEqual(self.ssh_calls.read_text().count("SSH attempt"), 1)
        self.assertNotIn("DEPLOYMENT COMPLETE", result.stdout)


if __name__ == "__main__":
    unittest.main()
