"""Validate rendered Kubernetes manifests without contacting a cluster.

Usage: python kubernetes/validate.py RENDERED_YAML dev|prod
"""

import re
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
    "kube-state-metrics",
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
    for pvc in EXPECTED_PVCS:
        annotations = objects["PersistentVolumeClaim", pvc]["metadata"]["annotations"]
        assert (
            annotations["argocd.argoproj.io/sync-options"]
            == "Prune=confirm,Delete=false"
        ), pvc
    assert "data-update" in names("CronJob")
    assert "job-market" in names("Ingress")

    # Overlay-specific environment variable is merged into the shared
    # generated ConfigMap. Ensure Kustomize rewrites envFrom references to
    # its hashed name and that the other shared settings remain intact.
    settings_maps = [
        m
        for m in manifests
        if m["kind"] == "ConfigMap"
        and m["metadata"]["name"].startswith("job-market-settings-")
    ]
    assert len(settings_maps) == 1, settings_maps
    settings = settings_maps[0]
    assert settings["data"]["DEPLOYMENT_ENV"] == (
        "development" if namespace == "dev" else "production"
    )
    assert settings["data"]["DASH_DEBUG"] == "false"
    settings_ref = {"configMapRef": {"name": settings["metadata"]["name"]}}
    for deployment in ("backend", "frontend", "airflow"):
        containers = objects["Deployment", deployment]["spec"]["template"]["spec"][
            "containers"
        ]
        assert any(
            settings_ref in container.get("envFrom", []) for container in containers
        ), deployment

    # ClusterRoles and ClusterRoleBindings are deliberately cluster-scoped.
    # Every other resource must remain in the selected environment namespace.
    application_image_tags = set()
    ghcr_images = {
        "ghcr.io/skrutikov/german-job-market-analytics",
        "ghcr.io/skrutikov/german-job-market-analytics-airflow",
    }
    for manifest in manifests:
        if manifest["kind"] in {"ClusterRole", "ClusterRoleBinding"}:
            assert manifest["metadata"].get("namespace") is None, manifest
        else:
            assert manifest["metadata"].get("namespace") == namespace, manifest
        assert manifest["kind"] != "Secret", "Credentials must not be committed"
        if manifest["kind"] == "Deployment":
            containers = manifest["spec"]["template"]["spec"]["containers"]
        elif manifest["kind"] == "CronJob":
            containers = manifest["spec"]["jobTemplate"]["spec"]["template"]["spec"][
                "containers"
            ]
        else:
            containers = []
        for container in containers:
            image = container["image"]
            if image.startswith("ghcr.io/skrutikov/"):
                name, tag = image.rsplit(":", 1)
                assert name in ghcr_images, image
                assert re.fullmatch(r"sha-[0-9a-f]{40}", tag), image
                application_image_tags.add(tag)

    # The backend, frontend, Airflow and optional ETL Job are one tested release.
    assert len(application_image_tags) == 1, application_image_tags

    # The Prometheus account is allowed read-only access to node cAdvisor.
    prometheus = objects["Deployment", "prometheus"]
    assert (
        prometheus["spec"]["template"]["spec"]["serviceAccountName"]
        == "job-market-prometheus"
    )
    assert "job-market-prometheus" in names("ServiceAccount")
    assert "kube-state-metrics" in names("Role")
    assert "kube-state-metrics" in names("RoleBinding")

    role = objects["ClusterRole", f"job-market-{namespace}-cadvisor-reader"]
    binding = objects["ClusterRoleBinding", f"job-market-{namespace}-cadvisor-reader"]
    assert binding["subjects"] == [
        {
            "kind": "ServiceAccount",
            "name": "job-market-prometheus",
            "namespace": namespace,
        }
    ]
    assert role["rules"] == [
        {
            "apiGroups": [""],
            "resources": ["nodes"],
            "verbs": ["get", "list", "watch"],
        },
        {"apiGroups": [""], "resources": ["nodes/proxy"], "verbs": ["get"]},
    ]

    etl_job = objects["CronJob", "data-update"]
    assert etl_job["spec"]["suspend"] is True, "Airflow owns the ETL schedule"
    print(f"{namespace}: validated {len(manifests)} resources")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    validate(Path(sys.argv[1]), sys.argv[2])
