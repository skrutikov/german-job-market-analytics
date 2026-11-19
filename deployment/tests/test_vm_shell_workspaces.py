"""Offline tests for Terraform workspace orchestration and Bash scripts."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
DR_TEST = Path(__file__).resolve().parent.parent / "dr" / "test_restore_cli.sh"


class VmWorkspaceShellTests(unittest.TestCase):
    def test_shell_syntax(self):
        scripts = (
            "deploy.sh",
            "destroy.sh",
            "restore_backup.sh",
            "setup_vm.sh",
            "terraform_vm_workspace.sh",
        )
        argo = SCRIPTS.parent / "argocd"
        paths = [*(str(SCRIPTS / name) for name in scripts)]
        paths.extend(
            (
                str(argo / "bootstrap.sh"),
                str(argo / "bootstrap-prod.sh"),
                str(argo / "configure-sync.sh"),
            )
        )
        result = subprocess.run(
            ["bash", "-n", *paths],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def run_workspace(self, mode, exists=False, inherited_workspace=None):
        with tempfile.TemporaryDirectory() as directory:
            terraform = Path(directory) / "terraform"
            terraform.write_text(
                "#!/usr/bin/env bash\n"
                'case "$*" in\n'
                '  *"init -input=false"*) : ;;\n'
                '  *"workspace list"*)\n'
                '    if [[ "${MOCK_EXISTS:-}" == yes ]]; then\n'
                "      printf '  default\\n* vm-103\\n'\n"
                "    else\n"
                "      printf '* default\\n'\n"
                "    fi ;;\n"
                '  *"workspace new vm-103"*) : ;;\n'
                '  *"workspace select vm-103"*) : ;;\n'
                '  *"workspace show"*) echo "${TF_WORKSPACE:-default}" ;;\n'
                '  *) echo "Unexpected Terraform call: $*" >&2; exit 1 ;;\n'
                "esac\n"
            )
            terraform.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{directory}:{env['PATH']}",
                    "MOCK_EXISTS": "yes" if exists else "no",
                }
            )
            env.pop("TF_WORKSPACE", None)
            if inherited_workspace:
                env["TF_WORKSPACE"] = inherited_workspace
            source = SCRIPTS / "terraform_vm_workspace.sh"
            command = (
                f'VM_ID=103; TF_DIR="{directory}"; '
                f'source "{source}"; '
                f"terraform_vm_workspace {mode}; "
                'echo "Selected: $TF_WORKSPACE"'
            )
            return subprocess.run(
                ["bash", "-euo", "pipefail", "-c", command],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

    def test_create_workspace(self):
        result = self.run_workspace("create")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Selected: vm-103", result.stdout)

    def test_reuse_workspace(self):
        result = self.run_workspace("create", exists=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Selected: vm-103", result.stdout)

    def test_matching_inherited_workspace_is_supported(self):
        result = self.run_workspace("create", exists=True, inherited_workspace="vm-103")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Selected: vm-103", result.stdout)

    def test_missing_workspace_cannot_be_destroyed(self):
        result = self.run_workspace("existing")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No Terraform workspace vm-103", result.stderr)

    def test_external_workspace_mismatch(self):
        result = self.run_workspace("create", inherited_workspace="vm-999")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("conflicts with requested vm-103", result.stderr)

    def test_offline_recovery_guards(self):
        result = subprocess.run(
            ["bash", str(DR_TEST)], capture_output=True, text=True, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
