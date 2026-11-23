"""Offline tests for backup provenance collection (no cluster needed)."""

import unittest

from deployment.dr.record_metadata import render_metadata

RELEASE = "2b8f7d295af0340b0b920b6d2f7fb5fee5b836c8"
GIT_SHA = "70f42244d344de760f4d5200f1a51465b894e2a2"


def deployments():
    base = "ghcr.io/skrutikov/german-job-market-analytics"
    return {
        "items": [
            {
                "metadata": {"name": name},
                "spec": {"template": {"spec": {"containers": [{"image": image}]}}},
            }
            for name, image in {
                "backend": f"{base}:sha-{RELEASE}",
                "frontend": f"{base}:sha-{RELEASE}",
                "airflow": f"{base}-airflow:sha-{RELEASE}",
            }.items()
        ]
    }


def application(namespace="prod"):
    return {
        "metadata": {"name": f"job-market-{namespace}"},
        "spec": {
            "source": {
                "targetRevision": "production" if namespace == "prod" else "main"
            }
        },
        "status": {
            "sync": {"revision": GIT_SHA, "status": "OutOfSync"},
            "history": [{"revision": GIT_SHA}],
            "health": {"status": "Degraded"},
        },
    }


class MetadataTests(unittest.TestCase):
    def test_production_provenance(self):
        value = render_metadata(
            "prod", "20261118T140000Z", "k3s-vm", deployments(), application()
        )
        self.assertIn(f"Container release tag: sha-{RELEASE}", value)
        self.assertIn(f"Argo CD observed Git commit: {GIT_SHA}", value)
        self.assertIn(f"Argo CD last successful sync commit: {GIT_SHA}", value)
        self.assertIn("GitOps branch: production", value)
        self.assertIn("airflow image:", value)
        self.assertIn("Argo CD sync status: OutOfSync", value)

    def test_dev_branch(self):
        value = render_metadata(
            "dev", "20261118T140000Z", "k3s-vm", deployments(), application("dev")
        )
        self.assertIn("GitOps branch: main", value)

    def test_mismatch_is_rejected(self):
        items = deployments()
        items["items"][2]["spec"]["template"]["spec"]["containers"][0]["image"] = (
            "ghcr.io/skrutikov/german-job-market-analytics-airflow:sha-" + "a" * 40
        )
        with self.assertRaisesRegex(ValueError, "different release tags"):
            render_metadata("prod", "20261118T140000Z", "k3s-vm", items, application())

    def test_wrong_git_branch_rejected(self):
        app = application()
        app["spec"]["source"]["targetRevision"] = "main"
        with self.assertRaisesRegex(ValueError, "expected branch"):
            render_metadata("prod", "20261118T140000Z", "k3s-vm", deployments(), app)

    def test_unknown_git_revision_rejected(self):
        app = application()
        app["status"]["sync"]["revision"] = ""
        with self.assertRaisesRegex(ValueError, "observed Git revision"):
            render_metadata("prod", "20261118T140000Z", "k3s-vm", deployments(), app)


if __name__ == "__main__":
    unittest.main()
