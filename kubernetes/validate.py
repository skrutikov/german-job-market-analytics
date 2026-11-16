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

    # ClusterRoles and ClusterRoleBindings are deliberately cluster-scoped.
    # Every other resource must remain in the selected environment namespace.
    for manifest in manifests:
        if manifest["kind"] in {"ClusterRole", "ClusterRoleBinding"}:
            assert manifest["metadata"].get("namespace") is None, manifest
        else:
            assert manifest["metadata"].get("namespace") == namespace, manifest
        assert manifest["kind"] != "Secret", "Credentials must not be committed"
        if manifest["kind"] == "Deployment":
            for container in manifest["spec"]["template"]["spec"]["containers"]:
                image = container["image"]
                if image.startswith("ghcr.io/skrutikov/"):
                    # Both namespaces consume security-scanned images from main.
                    assert image.endswith(":main"), image

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
