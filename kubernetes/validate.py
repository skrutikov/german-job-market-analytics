"""Validate rendered Kubernetes manifests without contacting a cluster.

Usage: python kubernetes/validate.py RENDERED_YAML dev|prod
"""

import sys
from pathlib import Path

import yaml

EXPECTED_WORKLOADS = {
    "postgres",
    "elasticsearch",
    "backend",
    "frontend",
    "nginx",
    "airflow",
    "prometheus",
    "pushgateway",
    "alertmanager",
    "grafana",
}
EXPECTED_SERVICES = EXPECTED_WORKLOADS
EXPECTED_PVCS = {
    "postgres-data",
    "elasticsearch-data",
    "etl-data",
    "airflow-state",
    "prometheus-data",
    "grafana-data",
}


def validate(path: Path, namespace: str) -> None:
    manifests = [item for item in yaml.safe_load_all(path.read_text()) if item]
    objects = {(m["kind"], m["metadata"]["name"]): m for m in manifests}
    names = lambda kind: {name for obj_kind, name in objects if obj_kind == kind}
    assert namespace in {"dev", "prod"}
    assert EXPECTED_WORKLOADS <= names("Deployment")
    assert EXPECTED_SERVICES <= names("Service")
    assert EXPECTED_PVCS <= names("PersistentVolumeClaim")
    assert "data-update" in names("CronJob")
    assert "job-market" in names("Ingress")

    for manifest in manifests:
        assert manifest["metadata"].get("namespace") == namespace, manifest
        assert manifest["kind"] != "Secret", "Credentials must not be committed"
        if manifest["kind"] == "Deployment":
            for container in manifest["spec"]["template"]["spec"]["containers"]:
                image = container["image"]
                if image.startswith("ghcr.io/skrutikov/"):
                    expected_tag = "dev" if namespace == "dev" else "main"
                    assert image.endswith(":" + expected_tag), image

    etl_job = objects["CronJob", "data-update"]
    assert etl_job["spec"]["suspend"] is True, "Airflow owns the ETL schedule"
    print(f"{namespace}: validated {len(manifests)} resources")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    validate(Path(sys.argv[1]), sys.argv[2])
