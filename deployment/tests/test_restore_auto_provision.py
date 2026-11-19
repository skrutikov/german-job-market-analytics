"""Offline tests for the optional self-provisioning recovery entrypoint."""

import os
import pty
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class RestoreAutoProvisionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "deployment" / "scripts"
        scripts.mkdir(parents=True)
        dr = self.root / "deployment" / "dr"
        dr.mkdir(parents=True)
        shutil.copy2(
            REPO / "deployment/scripts/restore_backup.sh",
            scripts / "restore_backup.sh",
        )
        shutil.copy2(REPO / "deployment/dr/common.sh", dr / "common.sh")
        self.marker = self.root / "deploy-arguments.txt"
        deploy = scripts / "deploy.sh"
        deploy.write_text(
            "#!/usr/bin/env bash\n"
            'printf "%s\\n" "$*" > "$MOCK_DEPLOY_MARKER"\n'
            "exit 7\n"
        )
        deploy.chmod(0o755)
        self.restore = scripts / "restore_backup.sh"
        self.env = os.environ.copy()
        self.env["MOCK_DEPLOY_MARKER"] = str(self.marker)
        self.env.pop("DR_CONFIRM_RECOVERY", None)

    def run_with_tty(self, reply):
        master, slave = pty.openpty()
        try:
            process = subprocess.Popen(
                ["bash", str(self.restore), "104", "29", "prod"],
                stdin=slave,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=self.env,
            )
            os.close(slave)
            slave = -1
            os.write(master, (reply + "\n").encode())
            output, errors = process.communicate(timeout=8)
            return process.returncode, output, errors
        finally:
            if slave != -1:
                os.close(slave)
            os.close(master)

    def test_invalid_environment_and_octet_rejected_early(self):
        for arguments in (("104", "29", "dev"), ("104", "999", "prod")):
            with self.subTest(arguments=arguments):
                completed = subprocess.run(
                    ["bash", str(self.restore), *arguments],
                    env=self.env,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertNotEqual(completed.returncode, 0)
                self.assertFalse(self.marker.exists())

    def test_permissions_must_be_confirmed_before_provision(self):
        code, output, errors = self.run_with_tty("NO")
        self.assertNotEqual(code, 0)
        self.assertIn("pveum user token permissions", output)
        self.assertIn("VM.Allocate", output)
        self.assertIn("VM.Config.*", output)
        self.assertIn("Recovery cancelled before VM provisioning", errors)
        self.assertFalse(self.marker.exists())

    def test_yes_calls_infra_only_and_stops_on_deploy_failure(self):
        code, output, errors = self.run_with_tty("YES")
        self.assertNotEqual(code, 0)
        self.assertIn("Provisioning VM 104", output)
        self.assertEqual(self.marker.read_text().strip(), "104 29 prod --infra-only")
        self.assertIn("VM provisioning failed or was cancelled", errors)


if __name__ == "__main__":
    unittest.main()
