#!/usr/bin/env python3
"""Write non-secret, human-readable backup metadata from live k3s/Argo CD JSON."""

import argparse
import json
import re
from pathlib import Path

APP_IMAGE = "ghcr.io/skrutikov/german-job-market-analytics"
IMAGES = {"backend": APP_IMAGE, "frontend": APP_IMAGE, "airflow": APP_IMAGE + "-airflow"}
RELEASE_TAG = re.compile(r"sha-[0-9a-f]{40}\Z")
GIT_SHA = re.compile(r"[0-9a-f]{40}\Z")


def render_metadata(namespace, timestamp, host, deployments, application):
    """Verify expected release identities and format a plain-text record."""
    if namespace not in {"dev", "prod"}:
        raise ValueError("Namespace must be dev or prod")

    branch = "production" if namespace == "prod" else "main"
    app_name = "job-market-" + namespace
    if application.get("metadata", {}).get("name") != app_name:
        raise ValueError(f"Expected Argo CD Application {app_name}")
    source = application.get("spec", {}).get("source", {})
    if source.get("targetRevision") != branch:
        raise ValueError(f"Argo CD does not track expected branch {branch}")

    actual = {}
    for deployment in deployments.get("items", []):
        name = deployment.get("metadata", {}).get("name")
        if name not in IMAGES:
            continue
        containers = (
            deployment.get("spec", {})
            .get("template", {})
            .get("spec", {})
            .get("containers", [])
        )
        images = [container.get("image", "") for container in containers]
        prefix = IMAGES[name] + ":"
        candidates = [image for image in images if image.startswith(prefix)]
        if name in actual or len(candidates) != 1:
            raise ValueError(f"Missing or ambiguous image for {name}")
        tag = candidates[0][len(prefix) :]
        if not RELEASE_TAG.fullmatch(tag):
            raise ValueError(f"{name} does not use a valid release tag")
        actual[name] = (candidates[0], tag)

    if set(actual) != set(IMAGES):
        raise ValueError("Missing backend, frontend or Airflow Deployment")
    tags = {tag for _, tag in actual.values()}
    if len(tags) != 1:
        raise ValueError("Deployed application images have different release tags")

    status = application.get("status", {})
    sync = status.get("sync", {})
    observed = sync.get("revision", "")
    if not GIT_SHA.fullmatch(observed):
        raise ValueError("Argo CD has no valid observed Git revision")
    history = status.get("history") or []
    last_success = history[-1].get("revision", "") if history else ""
    if last_success and not GIT_SHA.fullmatch(last_success):
        raise ValueError("Argo CD has an invalid last successful sync revision")

    lines = [
        "Job Market Analytics — disaster-recovery backup metadata",
        f"Namespace: {namespace}",
        f"Backup started (UTC): {timestamp}",
        f"Source SSH host: {host}",
        f"GitOps Application: {app_name}",
        f"GitOps branch: {branch}",
        f"Argo CD observed Git commit: {observed}",
        f"Argo CD last successful sync commit: {last_success or 'unavailable'}",
        f"Argo CD sync status: {sync.get('status', 'unknown')}",
        f"Argo CD health: {status.get('health', {}).get('status', 'unknown')}",
        f"Container release tag: {next(iter(tags))}",
    ]
    for name in IMAGES:
        lines.append(f"{name} image: {actual[name][0]}")
    lines.extend(
        [
            "",
            "The image SHA identifies the built source; the GitOps SHA",
            "identifies the deployment configuration. They may differ.",
            "Argo CD may be OutOfSync while backup writers are scaled to zero.",
            "Images above were read from running-cluster Deployment specs.",
            "No credentials or backed-up data are included in this file.",
        ]
    )
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--namespace", choices=("dev", "prod"), required=True)
    parser.add_argument("--timestamp", required=True)
    parser.add_argument("--ssh-host", required=True)
    parser.add_argument("--deployments", type=Path, required=True)
    parser.add_argument("--application", type=Path, required=True)
    args = parser.parse_args()
    text = render_metadata(
        args.namespace,
        args.timestamp,
        args.ssh_host,
        json.loads(args.deployments.read_text()),
        json.loads(args.application.read_text()),
    )
    print(text, end="")


if __name__ == "__main__":
    main()
