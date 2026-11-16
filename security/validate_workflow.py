"""Static safety/coverage checks for our Trivy GitHub Actions workflow.

Run with: python security/validate_workflow.py
Requires PyYAML (already installed in the Kubernetes manifest CI job).
"""

from pathlib import Path

import yaml


def validate() -> None:
    workflow = yaml.load(
        Path(".github/workflows/trivy.yml").read_text(encoding="utf-8"),
        Loader=yaml.BaseLoader,  # Preserve the "on:" GitHub Actions key.
    )

    assert set(workflow["on"]) == {"pull_request", "push", "schedule", "workflow_dispatch"}
    assert workflow["permissions"]["contents"] == "read"
    assert workflow["permissions"]["security-events"] == "write"

    jobs = workflow["jobs"]
    assert set(jobs) == {"repository", "container_images"}
    assert {entry["component"]: entry["dockerfile"] for entry in
            jobs["container_images"]["strategy"]["matrix"]["include"]} == {
                "application": "Dockerfile",
                "airflow": "airflow/Dockerfile",
            }

    for job in jobs.values():
        steps = job["steps"]
        trivy = [
            step for step in steps
            if step.get("uses", "").startswith("aquasecurity/trivy-action@")
        ]
        assert len(trivy) == 2
        assert all(step["uses"] == "aquasecurity/trivy-action@v0.36.0"
                   for step in trivy)
        assert all(step["with"]["version"] == "v0.74.0" for step in trivy)
        report, gate = trivy

        assert report["with"]["format"] == "sarif"
        assert report["with"]["exit-code"] == "0"
        assert "CRITICAL" in report["with"]["severity"]
        assert gate["with"]["format"] == "table"
        assert gate["with"]["exit-code"] == "1"
        assert gate["with"]["severity"] == "CRITICAL"
        assert gate["with"]["ignore-unfixed"] == "true"
        assert not any(step.get("continue-on-error") == "true" for step in steps)

        assert any(
            step.get("uses") == "github/codeql-action/upload-sarif@v4"
            for step in steps
        )
        assert any(
            step.get("uses") == "actions/upload-artifact@v4"
            for step in steps
        )

    repository = jobs["repository"]["steps"]
    assert repository[1]["with"]["scanners"] == "vuln,secret,misconfig"
    image = jobs["container_images"]["steps"]
    assert image[2]["with"]["scanners"] == "vuln"
    assert Path(".dockerignore").exists()
    assert ".git" in Path(".dockerignore").read_text()
    print("Trivy CI coverage and gating validated.")


if __name__ == "__main__":
    validate()
