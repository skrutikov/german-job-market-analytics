"""Validate the Trivy CI workflow's coverage and security policy."""

from pathlib import Path

import yaml


def validate() -> None:
    path = Path(".github/workflows/trivy.yml")
    workflow = yaml.load(path.read_text(), Loader=yaml.BaseLoader)

    expected_events = {
        "workflow_call",
        "pull_request",
        "push",
        "schedule",
        "workflow_dispatch",
    }
    assert set(workflow["on"]) == expected_events
    assert workflow["permissions"]["contents"] == "read"
    assert workflow["permissions"]["security-events"] == "write"

    jobs = workflow["jobs"]
    assert set(jobs) == {"repository", "container_images"}
    containers = jobs["container_images"]["strategy"]["matrix"]["include"]
    components = {entry["component"]: entry["dockerfile"] for entry in containers}
    assert components == {
        "application": "Dockerfile",
        "airflow": "airflow/Dockerfile",
    }

    for job in jobs.values():
        steps = job["steps"]
        scans = [
            step
            for step in steps
            if step.get("uses", "").startswith("aquasecurity/trivy-action@")
        ]
        assert len(scans) == 2
        assert all(
            scan["uses"] == "aquasecurity/trivy-action@v0.36.0" for scan in scans
        )
        assert all(scan["with"]["version"] == "v0.76.2" for scan in scans)
        report, gate = scans

        assert report["with"]["format"] == "sarif"
        assert report["with"]["exit-code"] == "0"
        assert "CRITICAL" in report["with"]["severity"]
        assert gate["with"]["format"] == "table"
        assert gate["with"]["exit-code"] == "1"
        assert gate["with"]["severity"] == "CRITICAL"
        assert gate["with"]["ignore-unfixed"] == "true"
        assert not any(step.get("continue-on-error") == "true" for step in steps)

        used_actions = {step.get("uses") for step in steps}
        assert "github/codeql-action/upload-sarif@v4" in used_actions
        assert "actions/upload-artifact@v4" in used_actions

    repo_steps = jobs["repository"]["steps"]
    assert repo_steps[1]["with"]["scanners"] == "vuln,secret,misconfig"
    image_steps = jobs["container_images"]["steps"]
    image_scans = [
        step for step in image_steps if step.get("with", {}).get("scan-type") == "image"
    ]
    assert len(image_scans) == 2
    assert image_scans[0]["with"]["scanners"] == "vuln"
    assert image_scans[0]["with"].get("trivyignores") is None
    assert image_scans[1]["with"]["trivyignores"] == (
        "${{ matrix.component == 'airflow' && "
        "'deployment/security/trivy-airflow-exceptions.yaml' || '' }}"
    )
    patched_version_step = next(
        step
        for step in image_steps
        if step.get("name")
        == "Verify patched OS package version in final Airflow image"
    )
    assert patched_version_step["if"] == "${{ matrix.component == 'airflow' }}"
    assert "dpkg --compare-versions" in patched_version_step["run"]

    exceptions = yaml.safe_load(
        Path("deployment/security/trivy-airflow-exceptions.yaml").read_text()
    )
    assert exceptions["vulnerabilities"] == [
        {
            "id": "CVE-2026-99306",
            "purls": ["pkg:deb/debian/linux-libc-dev"],
            "statement": exceptions["vulnerabilities"][0]["statement"],
            "expired_at": __import__("datetime").date(2026, 12, 19),
        }
    ]
    assert ".git" in Path(".dockerignore").read_text()

    pipeline = yaml.load(
        Path(".github/workflows/kubernetes.yml").read_text(),
        Loader=yaml.BaseLoader,
    )
    publish = pipeline["jobs"]["publish"]
    release_scan = pipeline["jobs"]["security"]
    assert "security" in publish["needs"]
    assert release_scan["uses"] == "./.github/workflows/trivy.yml"
    assert release_scan["permissions"]["security-events"] == "write"
    print("Trivy CI coverage and release gating validated.")


if __name__ == "__main__":
    validate()
