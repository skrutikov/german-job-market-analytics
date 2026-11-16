"""Exercise Airflow VM scripts with a mock kubectl, without touching the VM."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
MOCK_SUDO = """#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
log_path = Path(os.environ["MOCK_LOG"])
with log_path.open("a") as output:
    output.write(" ".join(args) + "\\n")

if args[:4] != ["k3s", "kubectl", "-n", os.environ["MOCK_NS"]]:
    raise SystemExit("Unexpected kubectl invocation")

if "rollout" in args:
    print("deployment successfully rolled out")
elif "airflow" in args:
    command = args[args.index("airflow") + 1:]
    if command == ["version"]:
        print("3.4.0")
    elif command[:2] == ["dags", "list"]:
        if "--output" in command:
            if os.environ.get("MOCK_BAD_JSON") == "1":
                print("invalid JSON")
            else:
                print(json.dumps([{
                    "dag_id": "job_market_etl",
                    "is_paused": os.environ.get("MOCK_PAUSED") == "1",
                }]))
        else:
            print("job_market_etl")
    elif command[:2] == ["dags", "list-runs"]:
        if "--output" in command:
            state = os.environ.get("MOCK_ACTIVE", "")
            print(json.dumps([{"state": state}] if state else []))
        else:
            print("job_market_etl | sample_run | success")
    elif command[:2] == ["dags", "unpause"]:
        print("dag unpaused")
    elif command[:2] == ["dags", "trigger"]:
        print("manual run queued")
    else:
        raise SystemExit("Unrecognized Airflow command " + str(command))
else:
    raise SystemExit("Unrecognized kubectl command " + str(args))
"""


class AirflowScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        sudo = self.bin_dir / "sudo"
        sudo.write_text(MOCK_SUDO)
        sudo.chmod(0o755)
        k3s = self.bin_dir / "k3s"
        k3s.write_text("#!/bin/sh\nexit 0\n")
        k3s.chmod(0o755)
        self.log = self.root / "sudo.log"
        self.environment = os.environ.copy()
        self.environment.update(
            {
                "PATH": f"{self.bin_dir}:{self.environment['PATH']}",
                "MOCK_LOG": str(self.log),
                "MOCK_NS": "prod",
                "MOCK_PAUSED": "0",
                "MOCK_ACTIVE": "",
            }
        )

    def run_script(self, filename):
        return subprocess.run(
            ["bash", str(REPO_ROOT / filename), "prod"],
            env=self.environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def logged_calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_skips_trigger_when_dag_is_running(self):
        self.environment["MOCK_ACTIVE"] = "running"
        result = self.run_script("init_airflow.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Skipping manual ETL", result.stdout)
        self.assertNotIn("dags trigger", self.logged_calls())

    def test_skips_trigger_when_dag_is_queued(self):
        self.environment["MOCK_ACTIVE"] = "queued"
        result = self.run_script("init_airflow.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("dags trigger", self.logged_calls())

    def test_unpause_does_not_trigger_second_run(self):
        self.environment["MOCK_PAUSED"] = "1"
        result = self.run_script("init_airflow.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dags unpause", self.logged_calls())
        self.assertNotIn("dags trigger", self.logged_calls())

    def test_unpaused_idle_dag_triggers_once(self):
        result = self.run_script("init_airflow.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.logged_calls().count("dags trigger"), 1)

    def test_unparseable_status_never_triggers(self):
        self.environment["MOCK_BAD_JSON"] = "1"
        result = self.run_script("init_airflow.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("dags trigger", self.logged_calls())

    def test_status_script_is_read_only(self):
        result = self.run_script("check_airflow_state.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("namespace prod", result.stdout)
        self.assertIn("dags list-runs", self.logged_calls())
        self.assertNotIn("dags trigger", self.logged_calls())
        self.assertNotIn("dags unpause", self.logged_calls())


if __name__ == "__main__":
    unittest.main()
